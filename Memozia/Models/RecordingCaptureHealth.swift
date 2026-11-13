import Foundation

/// 当前采集状态与本次录音已经发生的损失分开保存；恢复不能抹掉历史缺口。
struct RecordingCaptureHealth: Sendable {
    enum SystemAudioState: Sendable { case unused, active, interrupted, recovering }
    /// 麦克风输入设备状态。
    /// 与系统音频分开存放：设备切换是「正在恢复」而不是「写盘失败」，
    /// 若混在同一个出口里，用户看到的会是「写入失败……建议停止后重新录制」。
    enum MicrophoneState: Sendable { case unused, active, unavailable, recovering }
    enum Event: Sendable {
        case interrupted(writerFailure: Bool = false)
        case sleep
        case beginRecovery
        case recovered
        case samplesDropped
        /// 麦克风输入设备消失或格式无效（可恢复中断）
        case microphoneUnavailable
        /// 麦克风正在按退避有限重试恢复
        case microphoneRecovering
        /// 麦克风恢复已由新代次首个音频缓冲写入确认
        case microphoneRecovered
        /// 麦克风启动/首包重试预算耗尽（尚未确认恢复）
        case microphoneRecoveryFailed
    }

    private(set) var sessionID: UUID?
    private(set) var systemAudio: SystemAudioState = .unused
    private(set) var microphone: MicrophoneState = .unused
    private(set) var hadSystemAudioInterruption = false
    private(set) var hadMicrophoneInterruption = false
    private(set) var hadSleep = false
    private(set) var hadWriterFailure = false
    private(set) var hadDroppedSamples = false

    private var microphoneMuted = false
    private var micRecoveryBeganAt: Date?
    private var micRecoveryMutedThroughout = false
    private var microphoneInterruption: RecordingCaptureReport.Interruption?
    private var systemInterruption: RecordingCaptureReport.Interruption?
    private var completedInterruptions: [RecordingCaptureReport.Interruption] = []

    /// 静音状态变化必须记录在整个恢复区间内，不能用停录时的静音状态倒推历史。
    mutating func microphoneMuteChanged(_ muted: Bool) {
        guard sessionID != nil else { return }
        microphoneMuted = muted
        if micRecoveryBeganAt != nil { micRecoveryMutedThroughout = micRecoveryMutedThroughout && muted }
        if var interruption = microphoneInterruption {
            interruption.mutedThroughout = interruption.mutedThroughout && muted
            microphoneInterruption = interruption
        }
    }

    init(usesSystemAudio: Bool = false, usesMicrophone: Bool = false, sessionID: UUID = UUID()) {
        self.sessionID = sessionID
        systemAudio = usesSystemAudio ? .active : .unused
        microphone = usesMicrophone ? .active : .unused
    }

    /// 停录冻结历史；迟到事件不得改写最终摘要或下一次会话。
    mutating func finish(at date: Date = Date()) {
        if microphone == .recovering, microphoneInterruption == nil {
            observe(.microphoneRecoveryFailed, at: date)
            microphoneRecoveryFailed()
        }
        closeMicrophone(at: date, recovered: false)
        closeSystem(at: date, recovered: false)
        sessionID = nil
    }

    @discardableResult
    mutating func handle(_ event: Event, sessionID: UUID, at date: Date = Date(), lastSuccessfulWriteAt: Date? = nil) -> Bool {
        guard self.sessionID == sessionID else { return false }
        observe(event, at: date, lastSuccessfulWriteAt: lastSuccessfulWriteAt)
        switch event {
        case .interrupted(let writerFailure): interrupt(writerFailure: writerFailure)
        case .sleep: sleep()
        case .beginRecovery: beginRecovery()
        case .recovered: recover()
        case .samplesDropped: samplesDropped()
        case .microphoneUnavailable: microphoneUnavailable()
        case .microphoneRecovering: microphoneRecovering()
        case .microphoneRecovered: microphoneRecovered()
        case .microphoneRecoveryFailed: microphoneRecoveryFailed()
        }
        return true
    }

    private mutating func interrupt(writerFailure: Bool = false) {
        guard systemAudio != .unused else { return }
        systemAudio = .interrupted
        hadSystemAudioInterruption = true
        hadWriterFailure = hadWriterFailure || writerFailure
    }

    private mutating func sleep() {
        hadSleep = true
        if systemAudio != .unused { interrupt() }
    }

    private mutating func beginRecovery() {
        guard systemAudio != .unused else { return }
        systemAudio = .recovering
    }

    /// 仅在新流真正成功写入首个音频样本后确认恢复。
    private mutating func recover() {
        guard systemAudio == .recovering || systemAudio == .interrupted else { return }
        systemAudio = .active
    }

    private mutating func samplesDropped() { hadDroppedSamples = true }

    /// 设备消失/格式无效：记录「本次录音发生过缺口」，等待有限重试。
    private mutating func microphoneUnavailable() {
        guard microphone != .unused else { return }
        microphone = .unavailable
        hadMicrophoneInterruption = true
    }

    private mutating func microphoneRecovering() {
        guard microphone != .unused else { return }
        microphone = .recovering
    }

    /// 仅在新代次首个缓冲成功写入后确认恢复；恢复**不清除**曾经缺口的记录，
    /// 只把「当前状态」从恢复中改回活跃。
    private mutating func microphoneRecovered() {
        guard microphone == .recovering || microphone == .unavailable else { return }
        microphone = .active
    }

    private mutating func microphoneRecoveryFailed() {
        guard microphone != .unused else { return }
        microphone = .unavailable
        hadMicrophoneInterruption = true
    }

    /// 时间仅为观察到的中断区间，不声称等同于精确的声音丢失时长。
    private mutating func observe(_ event: Event, at date: Date, lastSuccessfulWriteAt: Date? = nil) {
        switch event {
        case .microphoneRecovering:
            if micRecoveryBeganAt == nil {
                micRecoveryBeganAt = date
                micRecoveryMutedThroughout = microphoneMuted
            }
        case .microphoneUnavailable, .microphoneRecoveryFailed:
            if microphone != .unused, microphoneInterruption == nil {
                microphoneInterruption = .init(
                    track: .microphone, observedStart: micRecoveryBeganAt ?? date,
                    mutedThroughout: micRecoveryBeganAt == nil ? microphoneMuted : micRecoveryMutedThroughout,
                    lastSuccessfulWriteAt: lastSuccessfulWriteAt
                )
            }
        case .microphoneRecovered:
            closeMicrophone(at: date, recovered: true)
        case .interrupted, .sleep:
            if systemAudio != .unused, systemInterruption == nil {
                systemInterruption = .init(track: .systemAudio, observedStart: date)
            }
        case .recovered:
            closeSystem(at: date, recovered: true)
        default: break
        }
    }

    private mutating func closeMicrophone(at date: Date, recovered: Bool) {
        if var interruption = microphoneInterruption {
            interruption.observedEnd = date
            interruption.recovered = recovered
            completedInterruptions.append(interruption)
        }
        microphoneInterruption = nil
        micRecoveryBeganAt = nil
    }

    private mutating func closeSystem(at date: Date, recovered: Bool) {
        if var interruption = systemInterruption {
            interruption.observedEnd = date
            interruption.recovered = recovered
            completedInterruptions.append(interruption)
        }
        systemInterruption = nil
    }

    var report: RecordingCaptureReport {
        var report = RecordingCaptureReport(interruptions: completedInterruptions)
        if let interruption = microphoneInterruption { report.interruptions.append(interruption) }
        if let interruption = systemInterruption { report.interruptions.append(interruption) }
        if hadSleep { report.issues.append(.sleep) }
        if hadWriterFailure { report.issues.append(.systemWriterFailure) }
        if hadDroppedSamples { report.issues.append(.samplesDropped) }
        return report
    }

    var summary: String? { report.summary }
}
