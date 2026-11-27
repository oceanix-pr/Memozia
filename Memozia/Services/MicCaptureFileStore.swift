import Foundation
@preconcurrency import AVFoundation
import os

/// 文件只在 writer 上访问。admission 仅保护接收资格、入队顺序及统计，音频回调不等待文件写入。
final class MicCaptureFileStore: @unchecked Sendable {
    private let writer = DispatchQueue(label: "app.memozia.mic-file-writer", qos: .userInitiated)
    private let admission = NSLock()
    private let capacity: DispatchSemaphore
    private var storedFile: AVAudioFile?
    private var activeTap: UUID?
    private var metrics = Metrics()
    private static let logger = Logger(subsystem: "app.memozia", category: "MicrophoneWriter")

    static let defaultMaxPending = 32

    init(maxPending: Int = MicCaptureFileStore.defaultMaxPending) { capacity = DispatchSemaphore(value: maxPending) }

    struct Metrics {
        private static let upperBounds = [50, 100, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000, 32_000]
        private var histogram = [Int](repeating: 0, count: upperBounds.count + 1)
        private(set) var callbacks = 0
        private(set) var droppedFrames = 0
        private var maximum = 0

        mutating func record(microseconds: Int, dropped: Int) {
            callbacks += 1
            droppedFrames += dropped
            maximum = max(maximum, microseconds)
            histogram[Self.upperBounds.firstIndex { microseconds <= $0 } ?? Self.upperBounds.count] += 1
        }

        var p99UpperMicroseconds: Int {
            var n = 0
            for (i, upper) in Self.upperBounds.enumerated() {
                n += histogram[i]
                if n * 100 >= callbacks * 99 { return min(upper, maximum) }
            }
            return maximum
        }
    }

    var statistics: Metrics { admission.withLock { metrics } }

    var file: AVAudioFile? {
        get { admission.withLock { storedFile } }
        set {
            writer.sync {
                let previous = admission.withLock {
                    let previous = storedFile
                    storedFile = newValue
                    return previous
                }
                // AVAudioFile 的析构可能关闭磁盘句柄，须在接收锁外完成。
                withExtendedLifetime(previous) {}
            }
        }
    }

    func activate(_ tap: UUID) {
        admission.withLock { activeTap = tap; metrics = Metrics() }
    }

    func invalidateTap() {
        let last: Metrics? = admission.withLock {
            guard activeTap != nil else { return nil }
            activeTap = nil
            return metrics
        }
        writer.sync {}
        if let last {
            Self.logger.debug("麦克风回调数=\(last.callbacks) p99上界μs=\(last.p99UpperMicroseconds) 丢失帧=\(last.droppedFrames)")
        }
    }

    func isCurrentTap(_ tap: UUID) -> Bool { admission.withLock { activeTap == tap } }

    enum Admission { case accepted, retired, full, invalidBuffer }
    typealias Write = @Sendable (AVAudioFile) -> Void

    func enqueue(tap: UUID, frames: Int, prepare: () -> Write?) -> Admission {
        let start = DispatchTime.now().uptimeNanoseconds
        return admission.withLock {
            guard activeTap == tap, storedFile != nil else { return .retired }
            var dropped = frames
            defer {
                metrics.record(microseconds: Int((DispatchTime.now().uptimeNanoseconds - start) / 1000), dropped: dropped)
            }
            guard capacity.wait(timeout: .now()) == .success else { return .full }
            guard let work = prepare() else { capacity.signal(); return .invalidBuffer }
            writer.async { [self] in
                defer { capacity.signal() }
                if let file = storedFile { work(file) }
            }
            dropped = 0
            return .accepted
        }
    }

    /// 控制路径（睡眠补静音）也按同一 FIFO 顺序写入。
    @discardableResult
    func write(tap: UUID? = nil, matching expectedFile: AVAudioFile? = nil,
               _ body: (AVAudioFile) throws -> Void) rethrows -> Bool {
        try writer.sync {
            if let tap, !isCurrentTap(tap) { return false }
            guard let file = storedFile, expectedFile == nil || expectedFile === file else { return false }
            try body(file)
            return true
        }
    }
}

/// 一个槽位在回调复制期间及 writer 消费期间只有一个使用者，归还后才会再次借出。
final class MicBufferPool: @unchecked Sendable {
    final class Slot: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        init?(_ format: AVAudioFormat, capacity: AVAudioFrameCount) {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
            self.buffer = buffer
        }
    }

    private let lock = NSLock()
    private let format: AVAudioFormat
    private var available: [Slot]

    init(format: AVAudioFormat, frameCapacity: AVAudioFrameCount = 4096) {
        self.format = format
        available = (0..<MicCaptureFileStore.defaultMaxPending).compactMap { _ in Slot(format, capacity: frameCapacity) }
    }
    func recycle(_ slot: Slot) { lock.withLock { available.append(slot) } }

    func copy(_ input: UnsafePointer<AudioBufferList>, frames: AVAudioFrameCount, muted: Bool) -> Slot? {
        let cached = lock.withLock { available.popLast() }
        guard let slot = cached.flatMap({ $0.buffer.frameCapacity >= frames ? $0 : nil }) ?? Slot(format, capacity: max(4096, frames)) else { return nil }
        slot.buffer.frameLength = frames
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let dst = UnsafeMutableAudioBufferListPointer(slot.buffer.mutableAudioBufferList)
        guard src.count == dst.count else { recycle(slot); return nil }
        for (from, to) in zip(src, dst) {
            guard from.mNumberChannels == to.mNumberChannels, from.mDataByteSize >= to.mDataByteSize,
                  let source = from.mData, let dest = to.mData else { recycle(slot); return nil }
            if muted { memset(dest, 0, Int(to.mDataByteSize)) }
            else { memcpy(dest, source, Int(to.mDataByteSize)) }
        }
        return slot
    }
}
