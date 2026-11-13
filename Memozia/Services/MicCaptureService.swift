import Foundation
import AVFoundation
import os.log

/// 麦克风采集服务
///
/// 基于 AVAudioEngine 采集麦克风输入，写入 CAF(PCM) 分片文件。
/// 分片为崩溃安全容器（头部在文件开头、数据线性追加）：异常退出后仅需
/// 修补头部 size 字段即可完整恢复（见 FileSyncService 崩溃恢复），
/// 最终在停止录音时统一导出为 m4a(AAC)（见 MeetingRecorderService）。
/// 支持本地静音/解除静音：tap 保持安装，静音时写入全零缓冲以维持时间轴。
///
/// 线程安全说明：
/// - 本类不是 @MainActor（installTap 闭包在后台音频线程执行，
///   若类为 @MainActor 则闭包会继承主 actor 隔离，导致运行时崩溃）。
/// - 本类是 @unchecked Sendable，内部通过 stateLock 保护跨线程访问的状态。
/// - tap 闭包访问的 fileBox、静音标志和零缓冲均由各自的锁保护。
final class MicCaptureService: @unchecked Sendable {

    /// 注入权限、设备绑定及引擎创建便于离线验证失败/取消，不触碰真实音频设备。
    @MainActor init(
        permissionCheck: @escaping @Sendable () async -> Bool = { await MicCaptureService.ensureMicrophonePermission() },
        bindInput: @escaping @MainActor (AVAudioEngine) throws -> UInt32 = MicCaptureService.bindInputDevice,
        makeEngine: @escaping @MainActor () -> AVAudioEngine = { AVAudioEngine() },
        startEngine: @escaping @MainActor (AVAudioEngine) throws -> Void = { engine in
            engine.prepare()
            try engine.start()
        }
    ) {
        self.permissionCheck = permissionCheck
        self.bindInput = bindInput
        self.makeEngine = makeEngine
        self.startEngine = startEngine
    }

    private let permissionCheck: @Sendable () async -> Bool
    @MainActor private let bindInput: (AVAudioEngine) throws -> UInt32
    @MainActor private let makeEngine: () -> AVAudioEngine
    @MainActor private let startEngine: (AVAudioEngine) throws -> Void

    private let logger = Logger(subsystem: "app.memozia", category: "MicCapture")
    // 引擎及节点仅在 MainActor 操作；音频回调只捕获文件盒和不可变标识。
    @MainActor private var engine: AVAudioEngine?
    @MainActor private var engineGeneration = 0
    @MainActor private var isStarting = false
    @MainActor private var initialURL: URL?
    @MainActor private var lastAttemptError: (any Error)?
    @MainActor private var lastAttemptCanRetry = true
    @MainActor private var preparedDeviceID: UInt32?
    /// AVAudioFile 的线程安全包装（@unchecked Sendable）
    private let fileBox = MicCaptureFileStore()
    /// 状态锁：保护 isTapInstalled / recordingFormat 的跨线程访问
    private let stateLock = NSLock()
    private var _isTapInstalled = false
    /// 写入格式（首次安装 tap 时确定，保证 unmute 后一致）
    private var _recordingFormat: AVAudioFormat?

    /// 配置变化时由总控分配下一片编号；成功打开后再登记到合并列表。
    /// 这两个闭包只在主线程的配置变更处理里访问。
    @MainActor var nextSegmentForFormatChange: (() -> URL?)?
    @MainActor var onFormatChangeSegmentOpened: ((URL) -> Void)?

    private var isTapInstalled: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isTapInstalled }
        set { stateLock.lock(); defer { stateLock.unlock() }; _isTapInstalled = newValue }
    }

    private var recordingFormat: AVAudioFormat? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _recordingFormat }
        set { stateLock.lock(); defer { stateLock.unlock() }; _recordingFormat = newValue }
    }

    /// 静音状态：tap 保持安装、改写全零缓冲（保持分片时间轴连续，
    /// 混音后与系统音轨对齐；同时消除静音期的零帧空壳分片）
    private let silencedBox = SilencedBox()

    /// 写入错误上报节流（磁盘满/IO 故障时 tap 每 ~21ms 失败一次，不去抖会形成风暴）
    private let writeErrorBox = WriteErrorRateBox()

    /// 采集事件回调（可在后台音频线程触发）。
    /// 事件已区分「设备切换/恢复」与「真实写盘失败」，接收方不得再把可恢复中断统一当成写入失败上报。
    private var _onEvent: (@Sendable (MicCaptureEvent) -> Void)?
    var onEvent: (@Sendable (MicCaptureEvent) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onEvent }
        set { stateLock.lock(); defer { stateLock.unlock() }; _onEvent = newValue }
    }

    /// 采集会话代次：start/stop 时递增。事件携带代次，接收方跨 actor 排队后必须复核，
    /// 迟到的旧事件（停止后迅速重录）不得改写新会话状态。
    private var liveness = MicCaptureLiveness() // 与成功写入时间一起受 stateLock 保护。
    private var _writtenFrames: Int64 = 0
    private var segmentTimeline: RecordingSegmentTimelineStore?
    @MainActor private var deviceObservation: MicrophoneDeviceRegistry.ChangeObservation?
    @MainActor private var observedDeviceID: UInt32?
    @MainActor private var observedRoute: InputRoute?
    private struct InputRoute: Equatable {
        let target: UInt32?
        let rate: Double?
        let alive: Bool?
    }
    var hasRecentWrites: Bool {
        stateLock.withLock { liveness.lastWrite.map { $0.duration(to: .now) < MicCaptureLiveness.timeout } ?? false }
    }
    var writtenFrames: Int64 { stateLock.lock(); defer { stateLock.unlock() }; return _writtenFrames }
    private var _lastSuccessfulWriteAt: Date?
    var lastSuccessfulWriteAt: Date? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _lastSuccessfulWriteAt
    }
    private var _generation = 0
    var generation: Int { stateLock.lock(); defer { stateLock.unlock() }; return _generation }
    func isCurrentGeneration(_ value: Int) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return value == _generation
    }

    /// 首包确认绑定具体恢复尝试，不能让上一 tap 的迟到缓冲确认新尝试。
    /// tap 线程只在 stateLock 下取走 token；控制流程与 UI 事件均回主线程。
    private var pendingRecoveryAttempt: MicCaptureRecovery.Attempt?

    @MainActor private lazy var recoveryController: MicCaptureRecovery = MicCaptureRecovery(
        attempt: { [weak self] token in
            self?.applyRecoveryAttempt(token: token) ?? false
        },
        onStarted: { [weak self] attempt in
            guard let self, !self.isStarting else { return }
            self.emit(.recoveryStarted(
                attempt: attempt, maxAttempts: self.recoveryController.maxAttempts,
                generation: self.generation
            ))
        },
        onPacketTimeout: { [weak self] attempt in
            guard let self else { return }
            let failure = self.diagnostics(
                stage: .writeBuffer, attempt: attempt, deviceBound: nil,
                oldFormat: nil, newFormat: self.recordingFormat, error: nil
            )
            self.lastRecoveryFailure = failure
            self.logRecoveryFailure(attempt: attempt)
            if !self.isStarting { self.emit(.deviceUnavailable(failure)) }
        },
        onFailed: { [weak self] attempt in
            guard let self, let failure = self.lastRecoveryFailure else { return }
            self.logRecoveryFailure(attempt: attempt)
            if !self.isStarting {
                if self.lastAttemptCanRetry {
                    self.emit(.recoveryFailed(failure))
                } else {
                    self.emit(.writeFailed(
                        userSummary: UserFacingError.summary(for: self.lastAttemptError ?? CocoaError(.fileWriteUnknown)),
                        diagnostics: failure
                    ))
                }
            }
        },
        onRecovered: { [weak self] in
            guard let self else { return }
            self.stateLock.withLock { self.liveness.recovered() }
            self.logger.info("麦克风采集恢复确认：当前尝试已有音频缓冲成功写入")
            if !self.isStarting { self.emit(.recovered(generation: self.generation)) }
        },
        shouldRetry: { [weak self] in self?.lastAttemptCanRetry ?? false },
        onBudgetExhausted: { [weak self] attempt in
            guard let self else { return }
            self.lastRecoveryFailure = self.diagnostics(
                stage: .recoveryBudget, attempt: attempt, deviceBound: nil,
                oldFormat: nil, newFormat: self.recordingFormat, error: nil
            )
        }
    )

    /// 开始/停止时取消恢复任务，并在锁内使旧音频回调失效。
    @MainActor private func beginNewSession() {
        recoveryController.cancel()
        stateLock.lock()
        _generation += 1
        _lastSuccessfulWriteAt = nil
        _writtenFrames = 0
        liveness = MicCaptureLiveness()
        pendingRecoveryAttempt = nil
        stateLock.unlock()
        deviceObservation = nil
        observedRoute = nil
        observedDeviceID = nil
        lastConfigurationChangeAt = nil
        lastRecoveryFailure = nil
        lastAttemptError = nil
        lastAttemptCanRetry = true
        writeErrorBox.reset()
    }

    private func setPendingRecoveryAttempt(_ token: MicCaptureRecovery.Attempt?) {
        stateLock.lock()
        pendingRecoveryAttempt = token
        stateLock.unlock()
    }

    /// 最近一次恢复尝试失败的定位信息（供日志与最终失败上报）
    private var lastRecoveryFailure: MicCaptureDiagnostics?
    /// 最近一次处理设备配置变化的时刻：紧随其后的写失败视为切换症状
    /// （路由尚未稳定，此时写失败不是磁盘故障），仅在主线程读写
    private var lastConfigurationChangeAt: Date?

    /// 设备配置变化观察者（录音中切换/拔出输入设备时重建 tap，避免格式不匹配崩溃）
    private var configObserver: NSObjectProtocol?

    /// 当前是否正在采集
    @MainActor var isCapturing: Bool {
        isTapInstalled && engine?.isRunning == true
    }

    /// C-6: 检查麦克风权限是否已授予
    private static func checkMicrophonePermission() -> Bool {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        } else {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        return AVAudioSession.sharedInstance().recordPermission == .granted
        */
        #endif
    }

    /// C-6: 确保麦克风权限可用：未决（从未请求过）时发起系统授权请求。
    ///
    /// 旧实现只做只读预检，把「未决」当成「拒绝」直接抛错：系统从未收到过请求，
    /// 应用不会出现在「系统设置 → 隐私与安全性 → 麦克风」列表里，用户也无从授权
    /// （分发到新机器上表现为「麦克风面板里根本没有 Memozia」）。
    /// - Returns: true = 已授权
    private static func ensureMicrophonePermission() async -> Bool {
        if checkMicrophonePermission() { return true }
        #if os(macOS)
        if #available(macOS 14.0, *) {
            // 仅未决时请求：已拒绝时重复调用也不会再次弹窗，避免无谓等待
            guard AVAudioApplication.shared.recordPermission == .undetermined else { return false }
            return await AVAudioApplication.requestRecordPermission()
        } else {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return false }
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
        #else
        return false
        #endif
    }

    /// 新会话使用新引擎；首个非空缓冲成功落盘才返回就绪。
    @MainActor func start(to url: URL, initiallyMuted: Bool = false, timeline: RecordingSegmentTimelineStore? = nil) async throws {
        guard !isStarting, fileBox.file == nil, engine == nil else {
            throw MicCaptureError.alreadyCapturing
        }
        beginNewSession()
        segmentTimeline = timeline
        let session = generation
        isStarting = true
        initialURL = url
        silencedBox.set(initiallyMuted)
        defer {
            if isCurrentGeneration(session) {
                isStarting = false
                initialURL = nil
            }
        }
        do {
            let permissionGranted = await permissionCheck()
            try Task.checkCancellation()
            guard isCurrentGeneration(session) else { throw CancellationError() }
            guard permissionGranted else { throw MicCaptureError.microphonePermissionNotGranted }
            try await recoveryController.startAndWait()
            try Task.checkCancellation()
            guard isCurrentGeneration(session) else { throw CancellationError() }
        } catch {
            // 旧启动任务的迟到收尾不能停止随后建立的新会话。
            let failure: any Error
            if error is MicCaptureRecovery.Failure {
                failure = lastAttemptCanRetry ? MicCaptureError.startupFailed
                    : (lastAttemptError ?? MicCaptureError.startupFailed)
            } else {
                failure = error
            }
            if isCurrentGeneration(session) { stop() }
            throw failure
        }
    }

    /// 硬件格式是采样率/声道的依据。客户端输出格式可能仍是上一次设备的缓存，
    /// 只有与硬件一致时才沿用其 PCM 布局；否则准备硬件采样率的 Float32 tap。
    static func captureFormat(
        hardware: AVAudioFormat, client: AVAudioFormat, deviceSampleRate: Double? = nil
    ) throws -> AVAudioFormat {
        guard hardware.sampleRate.isFinite, hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw MicCaptureError.inputDeviceLost
        }
        let rate = deviceSampleRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? hardware.sampleRate
        if client.sampleRate == rate, client.channelCount == hardware.channelCount,
           client.commonFormat == .pcmFormatFloat32 {
            return client
        }
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: rate, channels: hardware.channelCount
        ) else { throw MicCaptureError.inputDeviceLost }
        return format
    }

    /// 初始化可能触发蓝牙重新协商，不能只比较启动前的格式。
    static func needsFormatReconfiguration(
        hardware: AVAudioFormat, client: AVAudioFormat, capture: AVAudioFormat,
        deviceSampleRate: Double? = nil
    ) -> Bool {
        guard let current = try? captureFormat(hardware: hardware, client: client, deviceSampleRate: deviceSampleRate) else {
            return true
        }
        return current != capture || client.sampleRate != current.sampleRate
            || client.channelCount != current.channelCount || client.commonFormat != current.commonFormat
            || client.isInterleaved != current.isInterleaved
    }

    @MainActor private static func bindInputDevice(_ engine: AVAudioEngine) throws -> UInt32 {
        guard let target = MicrophoneDeviceRegistry.resolvedDeviceID() else {
            throw MicCaptureError.inputDeviceLost
        }
        if MicrophoneDeviceRegistry.currentDeviceID(of: engine) != target {
            guard MicrophoneDeviceRegistry.apply(target, to: engine) else {
                throw MicCaptureError.inputDeviceLost
            }
        }
        return target
    }

    /// 先撤销写入资格，再移除观察者/tap、释放旧引擎。调用方保留录音文件和静音状态。
    @MainActor private func retireEngine() {
        fileBox.invalidateTap()
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        removeTapIfInstalled()
        engine?.stop()
        engine = nil
        engineGeneration += 1
    }

    @MainActor private func observeConfigurationChanges() {
        guard configObserver == nil, let engine else { return }
        let session = generation
        let originEngine = engineGeneration
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // 捕获注册时的标识，不能让旧通知读取到新会话/新引擎的代次。
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentGeneration(session),
                      self.engineGeneration == originEngine,
                      self.fileBox.file != nil, let engine = self.engine else { return }
                guard self.recoveryController.isActive || self.recoveryController.isConfirmed
                    || self.currentRoute() != self.observedRoute else { return }
                self.lastConfigurationChangeAt = Date()
                let hardware = engine.inputNode.inputFormat(forBus: 0)
                let client = engine.inputNode.outputFormat(forBus: 0)
                let target = MicrophoneDeviceRegistry.resolvedDeviceID()
                let deviceRate = target.flatMap { MicrophoneDeviceRegistry.nominalSampleRate(for: $0) }
                guard !engine.isRunning || target != self.preparedDeviceID
                    || self.recordingFormat.map({ Self.needsFormatReconfiguration(
                        hardware: hardware, client: client, capture: $0, deviceSampleRate: deviceRate
                    ) }) != false else { return }
                self.requestReconfiguration()
            }
        }
    }

    @MainActor private func currentRoute() -> InputRoute {
        let target = MicrophoneDeviceRegistry.resolvedDeviceID()
        return InputRoute(target: target, rate: target.flatMap { MicrophoneDeviceRegistry.nominalSampleRate(for: $0) },
                          alive: target.flatMap { MicrophoneDeviceRegistry.isAlive($0) })
    }

    @MainActor private func checkInputRoute() {
        guard fileBox.file != nil else { return }
        let route = currentRoute()
        guard route != observedRoute else { return }
        observedRoute = route // 重复通知不刷新恢复预算。
        lastConfigurationChangeAt = Date()
        requestReconfiguration()
    }

    /// 通知可能缺失，或 HAL 自动换设备后引擎仍显示运行。静音零缓冲也算成功写入。
    @MainActor func checkCaptureHealth() {
        guard !isStarting, fileBox.file != nil else { return }
        checkInputRoute()
        let running = isCapturing
        let active = recoveryController.isActive
        let needsRecovery = stateLock.withLock {
            liveness.shouldRecover(engineRunning: running, recoveryActive: active)
        }
        guard needsRecovery else { return }
        let failure = diagnostics(stage: .captureStalled, attempt: 0, deviceBound: nil,
                                  oldFormat: recordingFormat, newFormat: nil, error: nil)
        emit(.deviceUnavailable(failure))
        logger.error("麦克风持续无成功写入，触发有界恢复")
        requestReconfiguration()
    }

    /// 让在途尝试失效并提前进入下一次准备，不丢弃启动续体、不刷新预算。
    @MainActor private func requestReconfiguration() {
        fileBox.invalidateTap()
        setPendingRecoveryAttempt(nil)
        if recoveryController.isActive {
            recoveryController.invalidateAttempt()
        } else {
            // 启动失败已结算，等待原调用方清理；不要另起无等待方的恢复。
            if isStarting, !recoveryController.isConfirmed { return }
            handleConfigurationChange()
        }
    }

    /// 唤醒等重复请求加入在途恢复；真实配置变化通过 requestReconfiguration 使当前尝试失效。
    @MainActor
    @discardableResult
    private func handleConfigurationChange() -> Bool {
        guard fileBox.file != nil else { return false }
        if recoveryController.isActive { return isCapturing }
        lastRecoveryFailure = nil
        stateLock.withLock { liveness.recoveryBegan() }
        return recoveryController.start()
    }

    /// 同一轮格式协商复用输入节点；仅会话开始或无法继续使用引擎时重新创建。
    @MainActor
    private func applyRecoveryAttempt(token: MicCaptureRecovery.Attempt) -> Bool {
        setPendingRecoveryAttempt(nil)
        fileBox.invalidateTap()
        removeTapIfInstalled()
        engine?.stop()
        let previousFile = fileBox.file
        let oldFormat = recordingFormat
        let nextEngine = engine ?? makeEngine()
        engine = nextEngine
        let tapID = UUID()
        var deviceBound: Bool?
        var hardwareFormat: AVAudioFormat?
        var clientFormat: AVAudioFormat?
        var newFormat: AVAudioFormat?
        var deviceRate: Double?
        var stage: MicCaptureDiagnostics.Stage = .bindDevice
        var replacement: (url: URL, file: AVAudioFile)?
        var attemptedURL: URL?
        lastAttemptError = nil
        lastAttemptCanRetry = true
        do {
            // 返回即表示设备已对齐；绑定失败不能继续读取旧格式。
            let target = try bindInput(nextEngine)
            deviceBound = true
            stage = .readFormat
            let hardware = nextEngine.inputNode.inputFormat(forBus: 0)
            let client = nextEngine.inputNode.outputFormat(forBus: 0)
            hardwareFormat = hardware
            clientFormat = client
            deviceRate = MicrophoneDeviceRegistry.nominalSampleRate(for: target)
            let format = try Self.captureFormat(hardware: hardware, client: client, deviceSampleRate: deviceRate)
            newFormat = format
            preparedDeviceID = target
            observedRoute = currentRoute()
            if deviceObservation == nil || observedDeviceID != target {
                observedDeviceID = target
                let session = generation
                deviceObservation = MicrophoneDeviceRegistry.ChangeObservation(deviceID: target) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrentGeneration(session) else { return }
                        self.checkInputRoute()
                    }
                }
            }
            logger.debug("麦克风准备 引擎代次=\(self.engineGeneration) 设备=\(target) 硬件=\(hardware.sampleRate)Hz/\(hardware.channelCount)ch 客户端=\(client.sampleRate)Hz/\(client.channelCount)ch tap=\(format.sampleRate)Hz/\(format.channelCount)ch")

            stage = .openSegmentFile
            if previousFile == nil || (previousFile?.length ?? 0) > 0 || oldFormat.map({ Self.requiresNewSegment(from: $0, to: format) }) != false {
                let url: URL
                if previousFile == nil, let initialURL {
                    url = initialURL
                } else if let next = nextSegmentForFormatChange?() {
                    url = next
                } else { throw CocoaError(.fileWriteUnknown) }
                attemptedURL = url
                guard let settings = Self.fileSettings(for: format) else { throw MicCaptureError.inputDeviceLost }
                replacement = (url, try AVAudioFile(
                    forWriting: url, settings: settings,
                    commonFormat: format.commonFormat, interleaved: format.isInterleaved
                ))
            }
            if let replacement { fileBox.file = replacement.file }
            stage = .installTap
            setPendingRecoveryAttempt(token)
            fileBox.activate(tapID)
            try installTapOnEngine(inputNode: nextEngine.inputNode, format: format,
                                   recoveryAttempt: token, tapID: tapID)
            isTapInstalled = true
            observeConfigurationChanges()
            stage = .startEngine
            try startEngine(nextEngine)
            recordingFormat = format
            lastRecoveryFailure = nil
            if let replacement, previousFile != nil {
                onFormatChangeSegmentOpened?(replacement.url)
            }
            // prepare/start 也可能改变硬件格式；即使通知还没排到主线程也立即复核。
            if Self.needsFormatReconfiguration(
                hardware: nextEngine.inputNode.inputFormat(forBus: 0),
                client: nextEngine.inputNode.outputFormat(forBus: 0), capture: format,
                deviceSampleRate: MicrophoneDeviceRegistry.nominalSampleRate(for: target)
            ) {
                requestReconfiguration()
            }
            return true // 仍需当前 tap 首包成功写入才能确认就绪。
        } catch {
            if stage == .bindDevice { deviceBound = false }
            let failedEngineGeneration = engineGeneration
            setPendingRecoveryAttempt(nil)
            let nsError = error as NSError
            if nsError.domain == "com.apple.coreaudio.avfaudio", nsError.code == -10868 {
                // 保留已完成部分协商的输入节点；立即销毁会再次触发蓝牙格式切换。
                fileBox.invalidateTap()
                removeTapIfInstalled()
                nextEngine.stop()
            } else {
                retireEngine()
            }
            // 极少数启动失败会发生在首次回调之后；有数据的片必须登记保留。
            if let replacement, replacement.file.length > 0 {
                recordingFormat = newFormat
                if previousFile != nil { onFormatChangeSegmentOpened?(replacement.url) }
            } else {
                fileBox.file = previousFile
                if let attemptedURL, FileManager.default.fileExists(atPath: attemptedURL.path) {
                    // 先释放文件句柄再删除空壳。
                    replacement = nil
                    do { try FileManager.default.removeItem(at: attemptedURL) }
                    catch { logger.error("清理未启动的麦克风分片失败: \(error.localizedDescription)") }
                }
            }
            lastAttemptError = error
            lastAttemptCanRetry = stage != .openSegmentFile
            lastRecoveryFailure = diagnostics(
                stage: stage, attempt: token.number, deviceBound: deviceBound,
                oldFormat: oldFormat, newFormat: newFormat, error: error,
                hardwareFormat: hardwareFormat, clientFormat: clientFormat,
                originEngineGeneration: failedEngineGeneration, deviceSampleRate: deviceRate
            )
            logRecoveryFailure(attempt: token.number)
            // 蓝牙/设备切换时 HAL 与客户端格式短暂不一致，-10868 是本轮协商的中间结果。
            // 继续沿用有界重试；只有首包超时或最终失败才留下中断告警，不能把已自愈的协商报成录音故障。
            if let failure = lastRecoveryFailure, !isStarting, lastAttemptCanRetry,
               !failure.isFormatNegotiationFailure {
                emit(.deviceUnavailable(failure))
            }
            return false
        }
    }

    /// 仅当前 tap 的非空成功写入可确认恢复（静音的全零缓冲同样有效）。
    private func noteSuccessfulWrite(_ token: MicCaptureRecovery.Attempt?, session: Int, tapID: UUID, frames: Int) {
        guard fileBox.isCurrentTap(tapID) else { return }
        stateLock.lock()
        guard _generation == session else { stateLock.unlock(); return }
        _lastSuccessfulWriteAt = Date()
        _writtenFrames += Int64(frames)
        liveness.wrote()
        let accepted = token != nil && pendingRecoveryAttempt == token
        if accepted { pendingRecoveryAttempt = nil }
        stateLock.unlock()
        guard accepted, let token else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentGeneration(session), self.fileBox.isCurrentTap(tapID) else { return }
            self.recoveryController.confirmWrite(token)
        }
    }

    private func emit(_ event: MicCaptureEvent) {
        onEvent?(event)
    }

    /// 组装失败定位信息（不含任何会议内容）
    @MainActor private func diagnostics(
        stage: MicCaptureDiagnostics.Stage,
        attempt: Int,
        deviceBound: Bool?,
        oldFormat: AVAudioFormat?,
        newFormat: AVAudioFormat?,
        error: Error?,
        hardwareFormat: AVAudioFormat? = nil,
        clientFormat: AVAudioFormat? = nil,
        originEngineGeneration: Int? = nil,
        deviceSampleRate: Double? = nil
    ) -> MicCaptureDiagnostics {
        let nsError = error.map { $0 as NSError }
        let hardware = hardwareFormat ?? engine?.inputNode.inputFormat(forBus: 0)
        let client = clientFormat ?? engine?.inputNode.outputFormat(forBus: 0)
        return MicCaptureDiagnostics(
            stage: stage,
            generation: generation,
            attempt: attempt,
            deviceBound: deviceBound,
            oldSampleRate: oldFormat?.sampleRate,
            newSampleRate: newFormat?.sampleRate,
            oldChannelCount: oldFormat?.channelCount,
            newChannelCount: newFormat?.channelCount,
            errorDomain: nsError?.domain,
            errorCode: nsError?.code,
            detail: error?.localizedDescription,
            lastSuccessfulWriteAt: lastSuccessfulWriteAt,
            engineGeneration: originEngineGeneration ?? engineGeneration,
            hardwareSampleRate: hardware?.sampleRate,
            clientSampleRate: client?.sampleRate,
            hardwareChannelCount: hardware?.channelCount,
            clientChannelCount: client?.channelCount,
            deviceSampleRate: deviceSampleRate ?? engine.flatMap { engine in
                MicrophoneDeviceRegistry.currentDeviceID(of: engine)
                    .flatMap { MicrophoneDeviceRegistry.nominalSampleRate(for: $0) }
            }
        )
    }

    /// 恢复失败日志：阶段、会话代次、设备绑定结果、新旧采样率/声道、错误域与错误码。
    /// 这些字段是下次定位 `-10868`（kAudioUnitErr_FormatNotSupported）具体发生在哪一步的依据
    @MainActor private func logRecoveryFailure(attempt: Int) {
        guard let failure = lastRecoveryFailure else { return }
        let summary = "麦克风恢复失败 stage=\(failure.stage.rawValue) 会话代次=\(failure.generation) 尝试=\(attempt) 设备绑定=\(failure.deviceBound.map { String($0) } ?? "-") 采样率=\(failure.oldSampleRate.map { String($0) } ?? "-")→\(failure.newSampleRate.map { String($0) } ?? "-") 声道=\(failure.oldChannelCount.map { String($0) } ?? "-")→\(failure.newChannelCount.map { String($0) } ?? "-") 引擎代次=\(failure.engineGeneration) 硬件采样率=\(failure.hardwareSampleRate.map { String($0) } ?? "-") 客户端采样率=\(failure.clientSampleRate.map { String($0) } ?? "-") 设备采样率=\(failure.deviceSampleRate.map { String($0) } ?? "-") 错误域=\(failure.errorDomain ?? "-") 错误码=\(failure.errorCode.map { String($0) } ?? "-")"
        if failure.isFormatNegotiationFailure {
            logger.debug("\(summary, privacy: .public) 详情=\(failure.detail ?? "-", privacy: .private)")
        } else {
            logger.error("\(summary, privacy: .public) 详情=\(failure.detail ?? "-", privacy: .private)")
        }
    }

    /// 本地静音：tap 保持安装，改写全零缓冲。
    /// 系统 mute 检测触发或用户手动静音时调用。
    /// 相比旧版移除 tap 的实现：静音期间分片时间轴保持连续（混音模式与系统音轨对齐），
    /// 且轮转产生的分片不再是零帧空壳
    func mute() {
        silencedBox.set(true)
    }

    /// 解除静音：恢复真实音频写入。
    /// 引擎停转时可能已换设备或被睡眠停转：启动（幂等的）恢复流程；恢复结果由采集事件上报。
    /// 这里不再抛出——旧实现抛出会把「正在恢复」直接变成一条需要用户「停止后重新录制」的错误。
    @MainActor func unmute() {
        silencedBox.set(false)
        if fileBox.file != nil, engine?.isRunning != true {
            handleConfigurationChange()
        }
    }

    /// 唤醒兜底恢复：系统睡眠可能直接停掉引擎且不触发配置变化通知，
    /// 醒来后若引擎停转或 tap 丢失，按当前设备格式重装 tap 并重启。
    /// - Returns: true = 采集已处于活跃状态（本就在跑或恢复成功）
    @MainActor func ensureCapturing() -> Bool {
        // 无打开的写入文件 = 未在采集：明确返回 false，让上层能区分
        // “无需恢复”与“恢复失败”，而不是把未在录音误报成采集正常
        guard fileBox.file != nil else { return false }
        checkCaptureHealth()
        if isTapInstalled && engine?.isRunning == true, recoveryController.isConfirmed { return true }

        // 与设备配置通知走同一恢复路径：唤醒后格式也可能已经变化。
        handleConfigurationChange()
        return isCapturing
    }

    /// 分片轮转：关闭当前文件并打开新文件。
    /// CAF(PCM) 正常关闭后容器完整、立即可播放；即使异常退出未关闭，
    /// 修补头部 size 后仍可完整恢复（见 FileSyncService），最多丢最后几毫秒缓冲。
    /// 先创建新文件再原子替换，写入空窗期近似为零。
    /// - Parameter url: 新分片的目标 URL
    /// - Returns: 是否轮转成功（失败时保留旧文件继续写入）
    @MainActor func rotateSegment(to url: URL) -> Bool {
        guard isCapturing else { return false }
        guard let format = recordingFormat,
              let settings = Self.fileSettings(for: format) else { return false }
        do {
            let newFile = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            // 原子替换：旧文件引用释放时触发 close → finalize，旧分片即刻可播放
            fileBox.file = newFile
            return true
        } catch {
            reportWriteError(error, session: generation)
            return false
        }
    }

    /// CAF(PCM Int16) 写入参数（与当前采集格式匹配）。
    /// 分片用 PCM 而非 AAC：PCM 容器头部在文件开头、数据线性追加，
    /// 异常退出后修补头部 size 即可完整恢复；AAC 的 moov 采样表只在关闭时
    /// 写入，崩溃后 mdat 裸帧无边界标记，无法在 App 内恢复
    static func fileSettings(for format: AVAudioFormat) -> [String: Any]? {
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// AVAudioFile 的处理格式必须与 tap 缓冲一致；输入设备重新配置后不能继续
    /// 往旧采样率/声道布局的文件写入。相同格式的配置通知无需额外切片。
    static func requiresNewSegment(from old: AVAudioFormat, to new: AVAudioFormat) -> Bool {
        old != new
    }

    /// 安全移除 tap：以“资源是否存在”为判据，避免对未安装 tap 的 bus 调用
    /// `removeTap(onBus:)`（历史上会命中 `required condition is false` 断言），
    /// 并同步清空 `_isTapInstalled`，保证标志与实际状态一致
    @MainActor private func removeTapIfInstalled() {
        stateLock.lock()
        let wasInstalled = _isTapInstalled
        _isTapInstalled = false
        stateLock.unlock()
        guard wasInstalled else { return }
        engine?.inputNode.removeTap(onBus: 0)
    }

    /// 停止采集并关闭文件
    @MainActor func stop() {
        // 先使等待方和所有旧回调失效，再释放采集资源；重复停止同样安全。
        beginNewSession()
        isStarting = false
        initialURL = nil
        retireEngine()
        silencedBox.set(false)
        fileBox.file = nil
        recordingFormat = nil
        preparedDeviceID = nil
        segmentTimeline = nil
    }

    /// 安装 tap（nonisolated：切断与调用方 actor 的隔离关联）
    /// 这样闭包不会被推断为 @MainActor 隔离，可在后台音频线程安全执行。
    /// isTapInstalled 的设置由调用方（start/unmute）在主线程完成。
    nonisolated private func installTapOnEngine(
        inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        recoveryAttempt: MicCaptureRecovery.Attempt?,
        tapID: UUID
    ) throws {
        if #available(macOS 27.0, iOS 27.0, tvOS 27.0, visionOS 27.0, *) {
            try installModernTap(on: inputNode, format: format, recoveryAttempt: recoveryAttempt, tapID: tapID)
        } else {
            installLegacyTap(on: inputNode, format: format, recoveryAttempt: recoveryAttempt, tapID: tapID)
        }
    }

    /// macOS 27 的只读音频 Tap。AVAudioFile 同版本提供只读 buffer 写入，
    /// 可避免为了保存实时输入而复制正常（非静音）采样。
    @available(macOS 27.0, iOS 27.0, tvOS 27.0, visionOS 27.0, *)
    nonisolated private func installModernTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        recoveryAttempt: MicCaptureRecovery.Attempt?,
        tapID: UUID
    ) throws {
        let session = generation
        let box = fileBox
        let silenced = silencedBox
        let zeroBox = MicCaptureZeroBufferBox() // 每个 tap 独立，避免新旧音频回调共用可变缓冲
        let writeErrors = WriteErrorRateBox()
        let timeline = segmentTimeline
        let tap: @Sendable (AVReadOnlyAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] buffer, time in
            guard let self, box.isCurrentTap(tapID) else { return }
            if silenced.isSilenced {
                guard let zero = zeroBox.zeroBuffer(
                    matching: buffer.format,
                    frameLength: AVAudioFrameCount(buffer.frameLength)
                ) else { return }
                do {
                    let didWrite = try box.write(tap: tapID) { file in
                        try file.write(from: AVReadOnlyAudioPCMBuffer(copying: zero))
                        timeline?.noteWrite(to: file.url, hostTime: time.isHostTimeValid
                            ? AVAudioTime.seconds(forHostTime: time.hostTime)
                            : CMClockGetTime(CMClockGetHostTimeClock()).seconds - Double(buffer.frameLength) / buffer.format.sampleRate,
                            frames: Int(buffer.frameLength))
                    }
                    if didWrite, buffer.frameLength > 0 { self.noteSuccessfulWrite(recoveryAttempt, session: session, tapID: tapID, frames: Int(buffer.frameLength)) }
                } catch {
                    self.reportWriteError(error, session: session, tapID: tapID, rateLimiter: writeErrors)
                }
                return
            }
            do {
                let didWrite = try box.write(tap: tapID) { file in
                    try file.write(from: buffer)
                        timeline?.noteWrite(to: file.url, hostTime: time.isHostTimeValid
                            ? AVAudioTime.seconds(forHostTime: time.hostTime)
                            : CMClockGetTime(CMClockGetHostTimeClock()).seconds - Double(buffer.frameLength) / buffer.format.sampleRate,
                            frames: Int(buffer.frameLength))
                }
                if didWrite, buffer.frameLength > 0 { self.noteSuccessfulWrite(recoveryAttempt, session: session, tapID: tapID, frames: Int(buffer.frameLength)) }
            } catch {
                self.reportWriteError(error, session: session, tapID: tapID, rateLimiter: writeErrors)
            }
        }
        try inputNode.installAudioTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            tapProvider: tap
        )
    }

    /// macOS 15–26 / iOS 18–26 兼容路径。
    @available(macOS, deprecated: 27.0)
    @available(iOS, deprecated: 27.0)
    @available(tvOS, deprecated: 27.0)
    @available(visionOS, deprecated: 27.0)
    nonisolated private func installLegacyTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        recoveryAttempt: MicCaptureRecovery.Attempt?,
        tapID: UUID
    ) {
        let session = generation
        let box = fileBox
        let silenced = silencedBox
        let zeroBox = MicCaptureZeroBufferBox() // 每个 tap 独立，避免新旧音频回调共用可变缓冲
        let writeErrors = WriteErrorRateBox()
        let timeline = segmentTimeline
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] buffer, time in
            guard let self, box.isCurrentTap(tapID) else { return }
            // 静音中：写全零缓冲，保持分片时间轴连续（用户预期静音 = 无真实麦克风数据）
            if silenced.isSilenced {
                guard let zero = zeroBox.zeroBuffer(matching: buffer.format, frameLength: buffer.frameLength) else { return }
                do {
                    let didWrite = try box.write(tap: tapID) { file in
                        try file.write(from: zero)
                        timeline?.noteWrite(to: file.url, hostTime: time.isHostTimeValid
                            ? AVAudioTime.seconds(forHostTime: time.hostTime)
                            : CMClockGetTime(CMClockGetHostTimeClock()).seconds - Double(buffer.frameLength) / buffer.format.sampleRate,
                            frames: Int(buffer.frameLength))
                    }
                    if didWrite, buffer.frameLength > 0 { self.noteSuccessfulWrite(recoveryAttempt, session: session, tapID: tapID, frames: Int(buffer.frameLength)) }
                } catch {
                    self.reportWriteError(error, session: session, tapID: tapID, rateLimiter: writeErrors)
                }
                return
            }
            do {
                let didWrite = try box.write(tap: tapID) { file in
                    try file.write(from: buffer)
                        timeline?.noteWrite(to: file.url, hostTime: time.isHostTimeValid
                            ? AVAudioTime.seconds(forHostTime: time.hostTime)
                            : CMClockGetTime(CMClockGetHostTimeClock()).seconds - Double(buffer.frameLength) / buffer.format.sampleRate,
                            frames: Int(buffer.frameLength))
                }
                if didWrite, buffer.frameLength > 0 { self.noteSuccessfulWrite(recoveryAttempt, session: session, tapID: tapID, frames: Int(buffer.frameLength)) }
            } catch {
                // C-1: 传播写入错误而非静默吞掉，便于上层提示用户磁盘空间不足等问题
                self.reportWriteError(error, session: session, tapID: tapID, rateLimiter: writeErrors)
            }
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: tap)
    }

    /// 写失败上报（去抖）：磁盘满/IO 故障时 tap 每 ~21ms 失败一次，
    /// 不去抖会形成每秒 ~48 次的回调风暴（MainActor Task 创建 + 日志刷屏）。
    ///
    /// 上报前必须区分**成因**：
    /// - 磁盘满 / IO 故障 = 真实写入失败，点名「写入失败……建议停止后重新录制」；
    /// - 设备切换、格式变化或引擎停转期间写失败 = 只是**症状**，此时若仍按写入失败上报，
    ///   AirPods 断开这类可恢复中断就会一直显示「麦克风录音写入失败：处理失败，请重试……」。
    ///   这类必须改按设备事件处理并触发恢复流程。
    private func reportWriteError(
        _ error: Error, session: Int, tapID: UUID? = nil,
        rateLimiter: WriteErrorRateBox? = nil
    ) {
        guard isCurrentGeneration(session) else { return }
        if let tapID, !fileBox.isCurrentTap(tapID) { return }
        // 在音频线程节流，避免每个失败缓冲都创建 MainActor Task。
        // tap 独立节流盒，旧回调不能消耗新 tap 的告警额度。
        guard (rateLimiter ?? writeErrorBox).shouldEmit() else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentGeneration(session), self.fileBox.file != nil else { return }
            if let tapID, !self.fileBox.isCurrentTap(tapID) { return }
            let failure = self.diagnostics(
                stage: .writeBuffer, attempt: 0, deviceBound: nil,
                oldFormat: self.recordingFormat, newFormat: nil, error: error
            )
            self.logger.error("麦克风写入失败: domain=\(failure.errorDomain ?? "-", privacy: .public) code=\(failure.errorCode ?? -1) detail=\(error.localizedDescription, privacy: .private)")
            self.lastRecoveryFailure = failure
            if self.isStarting {
                self.lastAttemptError = error
                let nsError = error as NSError
                self.lastAttemptCanRetry = nsError.domain != NSCocoaErrorDomain
                    && nsError.domain != NSPOSIXErrorDomain && self.writeFailureIsDeviceTransition()
                if self.lastAttemptCanRetry {
                    // 留在当前预算内等待下一次尝试；不能重开 startAndWait 丢失续体。
                    self.requestReconfiguration()
                } else {
                    self.recoveryController.fail()
                }
            } else if self.writeFailureIsDeviceTransition() {
                self.emit(.deviceUnavailable(failure))
                self.requestReconfiguration()
            } else {
                self.emit(.writeFailed(userSummary: UserFacingError.summary(for: error), diagnostics: failure))
            }
        }
    }

    /// 写失败是否只是设备切换 / 引擎停转的症状（而不是磁盘或 IO 故障）。
    @MainActor
    private func writeFailureIsDeviceTransition() -> Bool {
        guard let engine else { return true }
        let current = engine.inputNode.inputFormat(forBus: 0)
        let rate = MicrophoneDeviceRegistry.currentDeviceID(of: engine)
            .flatMap { MicrophoneDeviceRegistry.nominalSampleRate(for: $0) } ?? current.sampleRate
        return Self.writeFailureIsDeviceTransition(
            engineRunning: engine.isRunning,
            secondsSinceConfigurationChange: lastConfigurationChangeAt.map { Date().timeIntervalSince($0) },
            recordedSampleRate: recordingFormat?.sampleRate,
            recordedChannelCount: recordingFormat?.channelCount,
            currentSampleRate: rate,
            currentChannelCount: current.channelCount
        )
    }

    /// 写失败成因判定（纯函数，便于离线回归）。
    ///
    /// 满足任一即判定为设备切换症状：引擎已停、刚处理过设备配置变化（路由尚未稳定）、
    /// 正在写入的分片格式已与输入节点不一致、或尚未建立写入格式。
    /// 真正的磁盘/IO 故障不满足这些条件，因此仍会走「写入失败」告警。
    static func writeFailureIsDeviceTransition(
        engineRunning: Bool,
        secondsSinceConfigurationChange: TimeInterval?,
        recordedSampleRate: Double?,
        recordedChannelCount: UInt32?,
        currentSampleRate: Double,
        currentChannelCount: UInt32
    ) -> Bool {
        if !engineRunning { return true }
        if let since = secondsSinceConfigurationChange, since < deviceTransitionWindow { return true }
        guard let recordedSampleRate, let recordedChannelCount else { return true }
        return currentSampleRate != recordedSampleRate || currentChannelCount != recordedChannelCount
    }

    /// 设备配置变化后视为「路由尚未稳定」的窗口（秒）
    static let deviceTransitionWindow: TimeInterval = 5

    /// 静音补写单次上限（秒）：48kHz/16bit/单声道 ≈ 96KB/s，30 分钟 ≈ 166MB，
    /// 覆盖几乎所有真实间隙（会议小憩/短暂合盖），同时限制异常场景
    ///（录音忘停 + 整夜睡眠）的磁盘消耗与写入耗时
    static let maxSilencePaddingSeconds: TimeInterval = 1800

    /// 向当前分片写入指定秒数的静音。
    /// 用于混音模式下的睡眠间隙补偿：系统音轨 PTS 连续、麦克风轨顺序拼接，
    /// 不补齐则恢复后两轨错位睡眠时长。必须在恢复写入（ensureCapturing）之前调用，
    /// 保证静音先于新数据落盘。
    /// - Returns: 实际写入的秒数（未在录音/格式异常时为 0）
    func writeSilence(for seconds: TimeInterval) async -> TimeInterval {
        let session = generation
        let capped = min(max(0, seconds), Self.maxSilencePaddingSeconds)
        guard capped > 0, let format = recordingFormat, let expectedFile = fileBox.file,
              format.sampleRate > 0 else { return 0 }
        let framesPerSecond = format.sampleRate
        var written: TimeInterval = 0
        while written < capped {
            guard !Task.isCancelled else { break }
            let remainSeconds = capped - written
            let frameCount = AVAudioFrameCount(min(framesPerSecond, remainSeconds * framesPerSecond))
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { break }
            buffer.frameLength = frameCount
            for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let data = audioBuffer.mData { memset(data, 0, Int(audioBuffer.mDataByteSize)) }
            }
            do {
                // 与 tap 回调使用同一把写锁：避免与后台音频线程并发写同一 AVAudioFile
                let didWrite = try fileBox.write(matching: expectedFile) { file in
                    try file.write(from: buffer)
                }
                guard didWrite else { break }
            } catch {
                reportWriteError(error, session: session)
                break
            }
            written += Double(frameCount) / framesPerSecond
            if Int(written) % 60 == 0 { await Task.yield() } // 长间隙补写时让出执行线程
        }
        return written
    }
}

// MARK: - 线程安全的 AVAudioFile 包装

/// 静音标志（线程安全布尔）：tap 保持安装、写入全零缓冲的静音实现
private final class SilencedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSilenced: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Bool) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

/// 全零 PCM 缓冲池：静音写入按传入缓冲格式/长度复用，每次取出前重新清零
final class MicCaptureZeroBufferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?
    func zeroBuffer(matching format: AVAudioFormat, frameLength: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        if let b = buffer, b.format == format, b.frameCapacity >= frameLength {
            b.frameLength = frameLength
        } else {
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
            b.frameLength = frameLength
            buffer = b
        }
        guard let b = buffer else { return nil }
        // interleaved PCM 只有一个数据指针，不能按声道数索引 floatChannelData。
        for audioBuffer in UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList) {
            if let data = audioBuffer.mData { memset(data, 0, Int(audioBuffer.mDataByteSize)) }
        }
        return b
    }
}

/// 写入错误上报节流（5 秒冷却）
private final class WriteErrorRateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmitAt: Date?
    func reset() { lock.lock(); defer { lock.unlock() }; lastEmitAt = nil }
    func shouldEmit(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let last = lastEmitAt, now.timeIntervalSince(last) < 5 { return false }
        lastEmitAt = now
        return true
    }
}

// MARK: - 麦克风采集错误类型

/// C-6: 麦克风采集相关错误
enum MicCaptureError: LocalizedError {
    case microphonePermissionNotGranted
    case inputDeviceLost
    case alreadyCapturing
    case startupFailed

    var errorDescription: String? {
        switch self {
        case .microphonePermissionNotGranted:
            return String(localized: "麦克风权限未授予。请到「系统设置 → 隐私与安全性 → 麦克风」中开启 Memozia，然后重新开始录音。")
        case .alreadyCapturing:
            return String(localized: "当前已有录音正在进行，请先停止后再开始新录音。")
        case .startupFailed:
            return String(localized: "麦克风未能启动，请检查当前输入设备的连接，然后重新开始录音。")
        case .inputDeviceLost:
            return String(localized: "麦克风输入设备已断开，录音已暂停。重新连接设备后会自动恢复采集。")
        }
    }
}

// MARK: - 麦克风采集事件

/// 一次麦克风采集动作的定位信息（不含任何会议内容）。
/// 存在的理由：日志此前把多个操作汇入同一个出口，`-10868` 这类错误码无法定位到
/// 「重绑设备 / 建分片 / 装 tap / 启动引擎 / 写缓冲」中的哪一步。
struct MicCaptureDiagnostics: Sendable {
    enum Stage: String, Sendable {
        case bindDevice
        case readFormat
        case openSegmentFile
        case installTap
        case startEngine
        case writeBuffer
        case recoveryBudget
        case captureStalled
    }

    let stage: Stage
    /// 采集会话代次（start/stop 递增）
    let generation: Int
    /// 恢复尝试序号（非恢复路径为 0）
    let attempt: Int
    /// 设备绑定结果：nil = 本次未尝试绑定
    let deviceBound: Bool?
    let oldSampleRate: Double?
    let newSampleRate: Double?
    let oldChannelCount: UInt32?
    let newChannelCount: UInt32?
    let errorDomain: String?
    let errorCode: Int?
    let detail: String?
    var lastSuccessfulWriteAt: Date? = nil
    var engineGeneration: Int = 0
    var hardwareSampleRate: Double? = nil
    var clientSampleRate: Double? = nil
    var hardwareChannelCount: UInt32? = nil
    var clientChannelCount: UInt32? = nil
    var deviceSampleRate: Double? = nil

    /// 仅启动/tap 安装阶段的格式不支持可作为内部协商重试；写盘等阶段不得据错误码降级告警。
    var isFormatNegotiationFailure: Bool {
        (stage == .startEngine || stage == .installTap)
            && errorDomain == "com.apple.coreaudio.avfaudio" && errorCode == -10868
    }
}

/// 麦克风采集事件：把「可恢复的设备切换/恢复」与「真实写盘失败」分开上报。
///
/// 二者此前共用同一个出口，上层统一包装成「麦克风录音写入失败……建议停止后重新录制」，
/// 于是 AirPods 断开、会议软件释放音频设备等可恢复中断被误报成写盘失败。
/// 事件携带采集会话代次，接收方跨 actor 排队后必须复核，迟到事件不得改写新会话。
enum MicCaptureEvent: Sendable {
    /// 输入设备消失或格式无效：采集暂停，等待有界重试
    case deviceUnavailable(MicCaptureDiagnostics)
    /// 正在按退避重试恢复
    case recoveryStarted(attempt: Int, maxAttempts: Int, generation: Int)
    /// 新代次首个音频缓冲已成功写入，恢复得到确认
    case recovered(generation: Int)
    /// 启动/首包重试预算耗尽：麦克风采集尚未确认恢复
    case recoveryFailed(MicCaptureDiagnostics)
    /// 真实写盘失败（磁盘满 / IO 故障）；`userSummary` 已本地化，可直接展示
    case writeFailed(userSummary: String, diagnostics: MicCaptureDiagnostics)

    /// 事件所属采集会话代次
    var generation: Int {
        switch self {
        case .deviceUnavailable(let diagnostics), .recoveryFailed(let diagnostics),
             .writeFailed(_, let diagnostics):
            return diagnostics.generation
        case .recoveryStarted(_, _, let generation), .recovered(let generation):
            return generation
        }
    }
}
