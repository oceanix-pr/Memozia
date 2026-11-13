import Foundation
#if os(macOS)
import CoreAudio

/// 麦克风静音监听器
///
/// 监听**当前采集设备**的 mute 属性变化：已指定麦克风时跟随该设备，未指定或设备已拔出时
/// 回退系统默认输入设备（与 MicCaptureService 的绑定规则一致）。
/// 当会议软件调用系统级静音（部分会议软件行为）或用户在系统设置中静音麦克风时，
/// 会触发 `kAudioDevicePropertyMute` 属性变化，本监听器通过回调通知上层。
///
/// 注意：部分会议软件（如 Zoom 默认行为）使用应用层静音，不会触发系统 mute 属性，
/// 此时需依赖 UI 上的本地手动静音开关；本身不暴露 mute 属性的设备（如部分外接麦）同理。
@MainActor
final class MicMuteMonitor: @unchecked Sendable {

    /// 静音状态变化回调（true = 已静音，false = 已解除静音）
    var onMuteChange: ((Bool) -> Void)?

    /// 状态锁：保护 isSystemMuted 的跨线程访问
    private let stateLock = NSLock()
    private var _isSystemMuted = false

    /// 当前是否处于系统级静音
    var isSystemMuted: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isSystemMuted }
        set { stateLock.lock(); defer { stateLock.unlock() }; _isSystemMuted = newValue }
    }

    /// 当前监听的设备 ID
    private var monitoredDeviceID: AudioDeviceID?

    /// 是否处于监听状态，由 start/stop 同步维护。
    /// 设备切换回调是异步派发的（回调里 `Task { bindToCaptureDevice() }`），可能在
    /// stop() 之后才执行；若不校验该标志，会在停止录音后重新注册监听器
    ///（幽灵回调 + 悬空裸指针）。同时用于阻止 start() 重复注册
    fileprivate var isMonitoring = false

    /// 默认输入设备变化监听的 property address（用于切换监听目标）
    private var defaultInputAddr: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// mute 属性 address（按设备动态构造）
    private func muteAddr() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// 系统对象 ID（kAudioObjectSystemObject 在 Swift 中是 Int32，需转换为 UInt32）
    private let systemObjectID = AudioObjectID(bitPattern: kAudioObjectSystemObject)

    /// 开始监听
    func start() {
        // 重复 start 不重复注册：重复注册会导致回调翻倍，且 stop 只能移除一份
        guard !isMonitoring else { return }
        isMonitoring = true

        // 1. 监听默认输入设备变化（设备切换时重新绑定 mute 监听）
        var defaultAddr = defaultInputAddr
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectAddPropertyListener(
            systemObjectID,
            &defaultAddr,
            defaultInputListenerProc,
            selfPtr
        )

        // 2. 绑定当前采集设备的 mute 监听
        bindToCaptureDevice()
    }

    /// 停止监听
    func stop() {
        // 先清标志：阻止已排队但尚未执行的设备切换回调在 stop 之后再注册监听器
        isMonitoring = false
        var defaultAddr = defaultInputAddr
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(
            systemObjectID,
            &defaultAddr,
            defaultInputListenerProc,
            selfPtr
        )
        if let devID = monitoredDeviceID {
            var addr = muteAddr()
            AudioObjectRemovePropertyListener(devID, &addr, muteListenerProc, selfPtr)
        }
        monitoredDeviceID = nil
    }

    /// 绑定到当前采集的输入设备（跟随已选麦克风，未选择/已拔出时回退系统默认）
    fileprivate func bindToCaptureDevice() {
        // 已停止监听（如 stop 之后迟到的设备切换回调）：不再注册新监听器
        guard isMonitoring else { return }
        // 解绑旧设备
        if let oldDevID = monitoredDeviceID {
            var oldAddr = muteAddr()
            AudioObjectRemovePropertyListener(oldDevID, &oldAddr, muteListenerProc,
                                              Unmanaged.passUnretained(self).toOpaque())
            monitoredDeviceID = nil
        }

        // 采集目标设备：跟随已选麦克风；未选择或已拔出时回退系统默认
        guard let devID = MicrophoneDeviceRegistry.resolvedDeviceID() else { return }

        // 读取初始 mute 状态
        var isMuted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        var muteAddress = muteAddr()
        let muteStatus = AudioObjectGetPropertyData(
            devID, &muteAddress, 0, nil, &muteSize, &isMuted
        )
        if muteStatus == noErr {
            isSystemMuted = (isMuted != 0)
        }

        // 注册 mute 属性监听
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectAddPropertyListener(devID, &muteAddress, muteListenerProc, selfPtr)
        monitoredDeviceID = devID
    }
}

// MARK: - C 回调桥接

/// 默认输入设备变化回调
private let defaultInputListenerProc: AudioObjectPropertyListenerProc = { _, _, _, data in
    // 设备切换时重新绑定 mute 监听到新设备
    guard let data = data else { return noErr }
    let monitor = Unmanaged<MicMuteMonitor>.fromOpaque(data).takeUnretainedValue()
    Task { @MainActor in
        guard monitor.isMonitoring else { return }
        monitor.bindToCaptureDevice()
    }
    return noErr
}

/// mute 属性变化回调
private let muteListenerProc: AudioObjectPropertyListenerProc = { objectID, _, _, data in
    guard let data = data else { return noErr }
    let monitor = Unmanaged<MicMuteMonitor>.fromOpaque(data).takeUnretainedValue()

    // 直接读取触发事件的设备（objectID）的 mute 值；
    // 不重新查默认设备，避免设备切换瞬间读到错误设备的状态
    Task { @MainActor in
        guard monitor.isMonitoring else { return }
        var isMuted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            objectID, &address, 0, nil, &size, &isMuted
        ) == noErr else { return }

        let muted = (isMuted != 0)
        monitor.isSystemMuted = muted
        monitor.onMuteChange?(muted)
    }

    return noErr
}
#endif
