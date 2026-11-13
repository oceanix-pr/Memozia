import Foundation
#if os(macOS)
import AVFoundation
import CoreAudio
import os.log
#endif

/// 一个可选的麦克风输入设备。
///
/// 与系统「声音 → 输入」的设备口径一致，**包含 Loopback 等虚拟/回环驱动**：
/// 会议软件能用它们，App 就不该把它们藏起来。
///
/// `uid` 是 CoreAudio 的设备 UID（与 `AVCaptureDevice.uniqueID` 取值一致），
/// 跨重插、跨系统语言稳定，是唯一适合持久化的标识；显示名会重复且随语言变化，不可用作键。
struct MicrophoneDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String
    /// 设备是否暴露系统静音属性；为 false 时「自动检测系统静音」对该设备无效
    let supportsMute: Bool

    var id: String { uid }
}

/// 麦克风设备枚举与选择。
///
/// 选择结果只作用于 App 自身采集链路：通过 AUHAL 的 `kAudioOutputUnitProperty_CurrentDevice`
/// 把 `AVAudioEngine` 输入节点绑定到目标设备，**不修改系统默认输入设备**，不影响其他应用。
enum MicrophoneDeviceRegistry {

    /// UserDefaults key：已选设备 UID（缺失即跟随系统默认）
    static let selectionDefaultsKey = "microphone_device_uid"

    // MARK: - 选择持久化（跨平台）

    /// 已选设备 UID；nil 表示跟随系统默认输入设备
    static func savedSelectionUID() -> String? {
        guard let uid = UserDefaults.standard.string(forKey: selectionDefaultsKey), !uid.isEmpty else {
            return nil
        }
        return uid
    }

    static func saveSelectionUID(_ uid: String?) {
        if let uid, !uid.isEmpty {
            UserDefaults.standard.set(uid, forKey: selectionDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectionDefaultsKey)
        }
    }

    #if os(macOS)

    private static let logger = Logger(subsystem: "app.memozia", category: "MicrophoneDevice")
    private static let systemObject = AudioObjectID(bitPattern: kAudioObjectSystemObject)

    // MARK: - 枚举

    /// 展示用设备列表缓存：一次枚举约 0.6ms（20+ 次 CoreAudio IPC），
    /// 而设置页每次渲染会读 3 次、菜单栏每秒读 1 次，逐次直查会在主线程白白累积。
    /// 只缓存「展示列表」；采集决策路径（deviceID(forUID:)/resolvedDeviceID）始终直查，
    /// 避免缓存过期影响录到哪个设备。
    private static let devicesCacheLock = NSLock()
    private static let devicesCache = DevicesCacheBox()
    private static let devicesCacheTTL: TimeInterval = 1

    private final class DevicesCacheBox: @unchecked Sendable {
        var devices: [MicrophoneDevice] = []
        var stamp: TimeInterval = 0
    }

    /// 当前系统上带输入通道的设备，与系统「声音 → 输入」列表口径一致
    static func availableDevices() -> [MicrophoneDevice] {
        devicesCacheLock.lock()
        let cached = devicesCache.devices
        let age = Date.timeIntervalSinceReferenceDate - devicesCache.stamp
        devicesCacheLock.unlock()
        if !cached.isEmpty, age < devicesCacheTTL { return cached }

        let fresh = enumerateDevices()
        devicesCacheLock.lock()
        devicesCache.devices = fresh
        devicesCache.stamp = Date.timeIntervalSinceReferenceDate
        devicesCacheLock.unlock()
        return fresh
    }

    /// 直查系统输入设备（绕过展示缓存）
    private static func enumerateDevices() -> [MicrophoneDevice] {
        inputDeviceIDs().compactMap { id in
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return MicrophoneDevice(
                uid: uid,
                name: stringProperty(id, kAudioObjectPropertyName) ?? uid,
                supportsMute: hasMuteProperty(id)
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 已保存的设备是否仍可用（供 UI 标注「已断开」）
    static func isSelectionAvailable() -> Bool {
        guard let uid = savedSelectionUID() else { return true }
        return deviceID(forUID: uid) != nil
    }

    /// 当前选择的显示名；未指定或设备已拔出返回 nil（调用方自行回退「跟随系统默认」文案）
    static func selectedDeviceName() -> String? {
        guard let uid = savedSelectionUID() else { return nil }
        return availableDevices().first { $0.uid == uid }?.name
    }

    // MARK: - 设备解析

    /// UID → 设备 ID；设备不存在返回 nil
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDeviceIDs().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid && isAlive($0) != false }
    }

    /// 蓝牙断连时设备 ID 可能暂时仍在设备列表中；只有明确失效才排除。
    static func isAlive(_ deviceID: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var alive = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive)
        guard status == noErr else {
            logger.debug("读取麦克风设备存活状态失败：OSStatus=\(status)")
            return nil
        }
        return alive != 0
    }

    /// 系统默认输入设备
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    /// 本次采集应当绑定的设备：已选设备仍存在则用它，否则回退系统默认
    static func resolvedDeviceID() -> AudioDeviceID? {
        if let uid = savedSelectionUID(), let selected = deviceID(forUID: uid) {
            return selected
        }
        return defaultInputDeviceID()
    }

    /// 直查目标设备当前采样率，避免蓝牙协商时新建输入节点仍暴露旧格式快照。
    /// 读取失败交给采集层回退节点格式，并通过 debug 留痕，不改变设备采样率。
    static func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard status == noErr, rate.isFinite, rate > 0 else {
            logger.debug("读取麦克风设备采样率失败：设备=\(deviceID) OSStatus=\(status)")
            return nil
        }
        return rate
    }

    // MARK: - 绑定

    /// 把设备绑定到引擎输入节点。必须在读取 `inputNode.outputFormat` 之前调用：输入格式随设备变化。
    @discardableResult
    static func apply(_ deviceID: AudioDeviceID, to engine: AVAudioEngine) -> Bool {
        guard let unit = engine.inputNode.audioUnit else { return false }
        var device = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            logger.error("麦克风设备绑定失败：OSStatus=\(status)")
            return false
        }
        return true
    }

    /// 引擎输入节点当前绑定的设备
    static func currentDeviceID(of engine: AVAudioEngine) -> AudioDeviceID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            &size
        ) == noErr else { return nil }
        return device
    }

    // MARK: - CoreAudio 读取

    /// 注册列表初始化后不变；CoreAudio 管理回调派发，释放时逐一注销。
    /// 回调只捕获调用方提供的 Sendable 闭包，不访问本 token 的状态。
    final class ChangeObservation: @unchecked Sendable {
        private struct Registration {
            let object: AudioObjectID
            var address: AudioObjectPropertyAddress
            let block: AudioObjectPropertyListenerBlock
        }
        private let registrations: [Registration]

        init(deviceID: AudioDeviceID, onChange: @escaping @Sendable () -> Void) {
            var installed: [Registration] = []
            let properties: [(AudioObjectID, AudioObjectPropertySelector)] = [
                (systemObject, kAudioHardwarePropertyDefaultInputDevice),
                (systemObject, kAudioHardwarePropertyDevices),
                (deviceID, kAudioDevicePropertyDeviceIsAlive),
                (deviceID, kAudioDevicePropertyNominalSampleRate)
            ]
            for (object, selector) in properties {
                var address = AudioObjectPropertyAddress(mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
                let status = AudioObjectAddPropertyListenerBlock(object, &address, .main, block)
                if status == noErr { installed.append(Registration(object: object, address: address, block: block)) }
                else { logger.error("监听麦克风设备变化失败：OSStatus=\(status) selector=\(selector)") }
            }
            registrations = installed
        }

        deinit {
            for var registration in registrations {
                let status = AudioObjectRemovePropertyListenerBlock(registration.object, &registration.address, .main, registration.block)
                if status != noErr { logger.debug("注销麦克风设备监听：OSStatus=\(status)") }
            }
        }
    }

    private static func inputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &devices) == noErr else {
            return []
        }
        return devices.filter { inputStreamCount($0) > 0 }
    }

    private static func inputStreamCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func hasMuteProperty(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectHasProperty(deviceID, &address)
    }

    #endif
}
