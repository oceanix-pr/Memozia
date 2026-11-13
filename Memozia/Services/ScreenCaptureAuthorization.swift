#if os(macOS)
import Foundation
import CoreGraphics
import ScreenCaptureKit
import os

/// 只在用户主动启动捕获时调用；不缓存授权、不重置 TCC，不创建采集流。
enum ScreenCaptureAuthorization {
    enum Failure: LocalizedError, Equatable {
        case denied
        case timedOut

        var errorDescription: String? {
            switch self {
            case .denied:
                return String(localized: "缺少屏幕录制权限，请在「系统设置 → 隐私与安全性 → 屏幕录制」中允许 Memozia。")
                    + "\n\n" + ScreenCaptureAuthorization.recoveryAdvice
            case .timedOut:
                return String(localized: "屏幕录制授权等待超时，请完成系统授权后重试。")
            }
        }
    }

    static var recoveryAdvice: String {
        String(localized: "更新后若权限已开启仍报错，请完全退出 Memozia，从系统设置的屏幕录制列表移除 Memozia，再添加当前应用并开启权限，最后重新打开。")
    }

    static func content(onScreenWindowsOnly: Bool = false) async throws -> SCShareableContent {
        await UpdatePermissionRepair.shared.prepareIfNeeded()
        try Task.checkCancellation()
        // CG 预检保留为无弹窗诊断。false 也可能是未决定或更新后的旧授权，
        // 不能据此在真正的 ScreenCaptureKit 授权请求之前直接终止。
        if !CGPreflightScreenCaptureAccess() {
            Logger(subsystem: "app.memozia", category: "ScreenCaptureAuthorization")
                .debug("屏幕权限预检未通过，等待 ScreenCaptureKit 确认授权")
        }
        return try await load {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenWindowsOnly)
        }
    }

    /// 框架的权限请求可能等待系统对话框或不响应取消；到点即返回。
    /// 迟到结果只留在本次调用的锁保护盒内，不能触发麦克风、writer 或 SCStream。
    static func load<Value>(
        timeout: TimeInterval = 60,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let result = LockedBox<Result<Value, any Error>?>(nil)
        let finished = await RacingWatchdog.race(name: "屏幕录制授权", timeout: timeout) {
            do { result.value = .success(try await operation()) }
            catch { result.value = .failure(error) }
        }
        try Task.checkCancellation()
        guard finished, let outcome = result.value else { throw Failure.timedOut }
        do { return try outcome.get() }
        catch {
            let nsError = error as NSError
            if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
                throw Failure.denied
            }
            throw error
        }
    }
}
#endif
