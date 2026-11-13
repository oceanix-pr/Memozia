import Foundation
import AVFoundation

/// 文件、tap 写入资格和写操作受同一把锁保护。撤销返回时旧 tap 的在途写入
/// 已完成，之后的迟到缓冲不能写入轮转后的文件或下一条录音。
/// 写操作只能经过同步写入闭包；控制线程只在撤销 tap 后检查旧文件。
final class MicCaptureFileStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFile: AVAudioFile?
    private var activeTap: UUID?

    var file: AVAudioFile? {
        get { lock.lock(); defer { lock.unlock() }; return storedFile }
        set { lock.lock(); defer { lock.unlock() }; storedFile = newValue }
    }

    func activate(_ tap: UUID) {
        lock.lock(); defer { lock.unlock() }
        activeTap = tap
    }

    func invalidateTap() {
        lock.lock(); defer { lock.unlock() }
        activeTap = nil
    }

    func isCurrentTap(_ tap: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeTap == tap
    }

    @discardableResult
    func write(
        tap: UUID? = nil,
        matching expectedFile: AVAudioFile? = nil,
        _ body: (AVAudioFile) throws -> Void
    ) rethrows -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let file = storedFile else { return false }
        if let tap, activeTap != tap { return false }
        if let expectedFile, file !== expectedFile { return false }
        try body(file)
        return true
    }
}
