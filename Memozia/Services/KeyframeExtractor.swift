import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os.log

/// 一帧关键帧：时间点（秒）+ JPEG 编码数据。
/// `TimeInterval` 与 `Data` 均为 Sendable，因此帧可以安全跨 Task/actor 边界传递，
/// 不需要像 `CGImage`/`AVAssetImageGenerator` 那样做 nonisolated(unsafe) 豁免。
struct VideoKeyframe: Sendable, Equatable {
    let time: TimeInterval
    private let inlineJPEGData: Data?
    private let cachedFileURL: URL?

    /// 新抽取的帧保持内联 Data；从磁盘复用的帧按访问加载，避免启动分析时
    /// 把最多 1024 张 JPEG 一次性常驻内存。
    var jpegData: Data {
        if let inlineJPEGData { return inlineJPEGData }
        guard let cachedFileURL else { return Data() }
        return (try? Data(contentsOf: cachedFileURL, options: [.mappedIfSafe])) ?? Data()
    }

    init(time: TimeInterval, jpegData: Data) {
        self.time = time
        self.inlineJPEGData = jpegData
        self.cachedFileURL = nil
    }

    init(time: TimeInterval, cachedFileURL: URL) {
        self.time = time
        self.inlineJPEGData = nil
        self.cachedFileURL = cachedFileURL
    }

    static func == (lhs: VideoKeyframe, rhs: VideoKeyframe) -> Bool {
        lhs.time == rhs.time && lhs.jpegData == rhs.jpegData
    }
}

/// 一帧的画面签名：左右哈希 + 上下哈希 + 3×3 分块平均亮度/RGB。
///
/// 为什么不能只用一路水平 dHash：它只比较每行左右相邻像素，因此
/// 「只有垂直方向的变化」（文档/代码滚动、逐行书写）与
/// 「左右明暗方向不变的变化」（整体换色、右下角共享小窗、纯色淡入淡出）
/// 会算出完全相同的哈希，被当成重复画面丢掉。上下路补齐垂直梯度，
/// 分块亮度均值补齐局部与色彩变化，三者共同判重才不漏画面。
struct FrameSignature: Sendable, Equatable {
    /// 左右相邻比较：9×8 网格 → 8 bit/行 × 8 行 = 64 bit
    let horizontal: UInt64
    /// 上下相邻比较：9×8 网格 → 7 行比较 × 9 列 = 63 bit
    let vertical: UInt64
    /// 3×3 分块平均亮度（行优先，0...255）
    let blockMeans: [UInt8]
    /// 3×3 分块 RGB 均值（每块依次 R/G/B，共 27 项）；旧测试/缓存构造可留空。
    let colorBlockMeans: [UInt8]
    /// 17×16 细节网格的左右/上下比较位，补捉同模板页面的小字和控件变化。
    let detailHorizontal: [UInt64]
    let detailVertical: [UInt64]

    init(
        horizontal: UInt64,
        vertical: UInt64,
        blockMeans: [UInt8],
        colorBlockMeans: [UInt8] = [],
        detailHorizontal: [UInt64] = [],
        detailVertical: [UInt64] = []
    ) {
        self.horizontal = horizontal
        self.vertical = vertical
        self.blockMeans = blockMeans
        self.colorBlockMeans = colorBlockMeans
        self.detailHorizontal = detailHorizontal
        self.detailVertical = detailVertical
    }
}

/// 一次画面变化事件：发生变化的时间点 + 那一刻的画面签名。
/// 事件必须一路带上签名，选代表帧时才能跨时间窗判重（见 `selectRepresentativeTimes`）；
/// 只传时间点会让同一段静止内容在不同窗口各占一个名额。
struct SceneEvent: Sendable, Equatable {
    let time: TimeInterval
    let signature: FrameSignature
}

/// 关键帧抽取失败
enum KeyframeError: LocalizedError {
    case unreadableVideo
    case noKeyframe

    var errorDescription: String? {
        switch self {
        case .unreadableVideo:
            return String(localized: "无法读取视频画面，可能文件已损坏、不含视频轨道或已被移动")
        case .noKeyframe:
            return String(localized: "未能从视频中抽到可用画面（抽到的帧全部重复或解码失败）")
        }
    }
}

/// 从导入时留存的原始视频里抽关键帧，供「画面要点」多模态请求使用。
///
/// 为什么必须分两阶段：为避免漏掉短暂画面，先用低分辨率缩略图高频扫描；
/// 一场 40 分钟的会议按 0.5 秒间隔会产生 4800 个候选点，不能全部解码成大图或送给模型。
/// 因此先用画面签名找出变化事件，折叠连续重复与 A→B→A 短暂过渡态，
/// 再把稳定重大变化解码成 1280px JPEG。
///
/// 默认链路不再按时长把整段视频压成固定 64 帧；稳定变化全部保留，模型侧每 8 张动态分批。
/// 只有摄像头、动画等极端动态素材超过 `maxKeyframes` 时才触发本地安全保护，
/// 并按时间覆盖收敛，避免生成数 GB 缓存和数百次网络请求。
enum KeyframeExtractor {

    private static let logger = Logger(subsystem: "app.memozia", category: "Keyframe")

    /// 代表帧名额下限：短视频至少给出 8 个时间槽位（只用于显式限额与兼容测试）。
    static let minKeyframes = 8
    /// 极端动态素材的本地安全上限。普通屏幕录制不按时长预算截断，而是保留全部稳定重大变化；
    /// 只有稳定事件超过该值时才按时间轴覆盖收敛，避免摄像头/动画视频生成数 GB 缓存和数百次请求。
    static let maxKeyframes = 1_024
    /// 兼容显式预算调用的目标密度；默认抽帧链路不再用它压缩稳定事件。
    static let keyframeTargetInterval: TimeInterval = 60
    /// 低分辨率画面扫描间隔下限（秒）：小于 1 秒，避免漏掉短暂出现的共享画面
    static let defaultScanInterval: TimeInterval = 0.5
    /// 扫描点数上限：超过后按 时长/上限 放宽间隔，避免超长视频产生数万个解码请求
    static let maxScanPoints = 10_000
    /// 扫描阶段要算两路差值哈希与 3×3 分块均值，24×24 采样已够用，96px 显著降低长视频解码成本
    static let scanPixelSize: CGFloat = 96
    /// 分批交给 AVAssetImageGenerator，避免长视频一次创建数千个异步请求
    static let scanBatchSize = 240
    /// 抽帧解码长边上限：1280 足够读清幻灯片正文，又避免 5K 全屏原始位图驻留内存
    static let maxPixelSize: CGFloat = 1280
    /// JPEG 质量：0.72 在"文字可读"与"请求体不爆"之间的实测折中点
    static let jpegQuality: Float = 0.72
    /// 差值哈希采样网格：9×8 灰度 → 左右相邻比较填满 64 bit，上下相邻比较占 63 bit
    static let hashGridWidth = 9
    static let hashGridHeight = 8
    /// 分块亮度均值：24×24 采样均分成 3×3 块（每块 8×8 像素）
    static let blockCountPerSide = 3
    static let blockSampleSide = blockCountPerSide * 8
    /// 细节哈希把 1280px 屏幕压到 17×16；比 9×8 粗哈希更容易看到标题、代码和控件变化。
    static let detailHashGridWidth = 17
    static let detailHashGridHeight = 16
    /// 合并位差阈值：≤ 该值才算同一画面。
    /// 注意 `6/64` 与 `12/127` 的比例同为 9.4%，这一路**没有**比旧值更灵敏；
    /// 比旧实现少误判重复的部分全部来自新增的分块亮度门（见 `isSameScene`）。
    static let duplicateBitThreshold = 12
    /// 细节哈希共 511 bit；≤24（约 4.7%）才允许继续判为同一画面。
    static let detailDuplicateBitThreshold = 24
    /// 硬转场位差：达到即立刻记事件，不受最小事件间隔约束（避免快速翻页被吞）
    static let hardCutBitThreshold = 26
    /// 分块亮度均值门：任一块平均亮度偏差超过该值即视为画面有变化（换色、局部小窗、淡入淡出）
    static let blockDeltaThreshold = 26
    /// 分块 RGB 门：结构和亮度都近似时，只要局部色彩变化明显仍视为新画面。
    static let colorBlockDeltaThreshold = 24
    /// 最小事件间隔（秒）：抑制摄像头噪声、光标闪烁把静止段炸成上千个事件
    static let defaultMinEventInterval: TimeInterval = 3
    /// 最长静默（秒）：超过该时长没有任何事件就强制补一个代表点，缓慢渐变不再长时间无输出
    static let defaultMaxSilenceInterval: TimeInterval = 30
    /// A→B→A 且 B 存在时间不超过该值时，把 B 当作切换动画、菜单闪现或加载中间态。
    /// 真正停留更久的弹窗/页面仍会作为独立事件保留。
    static let defaultTransientEventDuration: TimeInterval = 3

    // MARK: - 纯函数：扫描与代表时间点

    /// 以半个采样间隔为起点，按固定间隔覆盖整段视频；不取 0 与结尾以避开边界黑帧。
    static func scanTimes(duration: TimeInterval,
                          interval: TimeInterval = defaultScanInterval) -> [TimeInterval] {
        guard duration.isFinite, interval.isFinite, duration > 0, interval > 0 else { return [] }
        let first = min(interval / 2, duration / 2)
        var result: [TimeInterval] = []
        result.reserveCapacity(max(1, Int((duration / interval).rounded(.up))))
        var time = first
        while time < duration {
            result.append(time)
            time += interval
        }
        return result
    }

    /// 扫描间隔随时长自适应：短视频保留 0.5 秒以抓短暂画面，
    /// 超长视频按点数上限放宽，避免扫描阶段自身成为瓶颈。
    static func scanInterval(
        forDuration duration: TimeInterval,
        minimum: TimeInterval = defaultScanInterval
    ) -> TimeInterval {
        guard duration.isFinite, duration > 0, maxScanPoints > 0 else { return minimum }
        return max(minimum, duration / Double(maxScanPoints))
    }

    /// 代表帧名额：目标每 `keyframeTargetInterval` 秒一个，并夹在 `minKeyframes`...`maxKeyframes` 之间。
    static func keyframeBudget(duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0 else { return minKeyframes }
        let wanted = Int((duration / keyframeTargetInterval).rounded(.up))
        return min(max(wanted, minKeyframes), maxKeyframes)
    }

    /// 从变化检测结果中得到需要落盘和送模型的稳定事件：
    /// - 连续相同的 30 秒静默兜底点不重复占用图片/请求；
    /// - A→B→A 的短暂跳变按过渡态折叠；
    /// - 相同页面在经过其他页面后再次出现时仍保留其新时间点，不能做全局去重。
    static func significantSceneEvents(
        from events: [SceneEvent],
        transientDuration: TimeInterval = defaultTransientEventDuration,
        bitThreshold: Int = duplicateBitThreshold,
        blockDeltaThreshold: Int = blockDeltaThreshold
    ) -> [SceneEvent] {
        let sorted = events.filter { $0.time.isFinite }.sorted { $0.time < $1.time }
        guard let first = sorted.first else { return [] }

        var result = [first]
        var index = 1
        while index < sorted.count {
            let candidate = sorted[index]
            guard let previous = result.last else { break }

            if isSameScene(
                candidate.signature,
                asReferenceTo: previous.signature,
                bitThreshold: bitThreshold,
                blockDeltaThreshold: blockDeltaThreshold
            ) {
                index += 1
                continue
            }

            if transientDuration >= 0, index + 1 < sorted.count {
                let next = sorted[index + 1]
                let returnsQuickly = next.time - candidate.time <= transientDuration
                    && isSameScene(
                        next.signature,
                        asReferenceTo: previous.signature,
                        bitThreshold: bitThreshold,
                        blockDeltaThreshold: blockDeltaThreshold
                    )
                if returnsQuickly {
                    index += 1
                    continue
                }
            }

            result.append(candidate)
            index += 1
        }
        return result
    }

    /// 极端动态素材超过本地安全上限时按时间轴等窗保留事件。
    /// 这里故意不做全局画面去重：A→B→A 的第二次 A 是真实发生的时间节点，仍需进入时间线。
    static func selectTimelineCoverageTimes(
        events: [SceneEvent],
        duration: TimeInterval,
        limit: Int
    ) -> [TimeInterval] {
        guard limit > 0 else { return [] }
        let sorted = events.filter { $0.time.isFinite }.sorted { $0.time < $1.time }
        guard sorted.count > limit else { return sorted.map(\.time) }

        let fallbackSpan = (sorted.last?.time ?? 0) + 1
        let span = max(duration.isFinite ? duration : 0, fallbackSpan)
        let window = span / Double(limit)
        var selected: [SceneEvent] = []
        selected.reserveCapacity(limit)

        for bucket in 0..<limit {
            let start = Double(bucket) * window
            let end = bucket == limit - 1 ? span.nextUp : Double(bucket + 1) * window
            let candidates = sorted.filter { $0.time >= start && $0.time < end }
            guard !candidates.isEmpty else { continue }
            let target = (start + end) / 2
            selected.append(candidates.min {
                let lhs = abs($0.time - target)
                let rhs = abs($1.time - target)
                return lhs == rhs ? $0.time < $1.time : lhs < rhs
            }!)
        }

        if selected.count < limit {
            let selectedTimes = Set(selected.map(\.time))
            for event in sorted where !selectedTimes.contains(event.time) {
                selected.append(event)
                if selected.count == limit { break }
            }
        }
        return selected.map(\.time).sorted()
    }

    /// 从按时间排列的画面签名中保留发生明显画面变化的事件（时间点 + 那一刻的签名）。
    ///
    /// 以「最近一次已接受画面」为锚点比较（而不是与全部历史比较）：既过滤静止页编码噪声，
    /// 又能让渐进滚动把位差累积出来。在此之上加三条约束，去掉长视频的两个失效模式：
    /// - `minEventInterval`：抖动/噪声不再把一段静止画面炸成成百上千个事件；
    /// - `hardCutBitThreshold`：真转场即使在最小间隔内也立即记录，快速翻页不被吞；
    /// - `maxSilenceInterval`：距上次事件过久时无条件补点，保证时间轴不会长时间空白。
    static func sceneChangeTimes(
        from samples: [(time: TimeInterval, signature: FrameSignature)],
        bitThreshold: Int = duplicateBitThreshold,
        hardCutBitThreshold: Int = hardCutBitThreshold,
        blockDeltaThreshold: Int = blockDeltaThreshold,
        minEventInterval: TimeInterval = defaultMinEventInterval,
        maxSilenceInterval: TimeInterval = defaultMaxSilenceInterval
    ) -> [SceneEvent] {
        var result: [SceneEvent] = []
        var anchor: (time: TimeInterval, signature: FrameSignature)?
        for sample in samples.sorted(by: { $0.time < $1.time }) {
            guard let last = anchor else {
                result.append(SceneEvent(time: sample.time, signature: sample.signature))
                anchor = (sample.time, sample.signature)
                continue
            }
            let bits = bitDistance(sample.signature, last.signature)
            let sameScene = isSameScene(
                sample.signature, asReferenceTo: last.signature,
                bitThreshold: bitThreshold, blockDeltaThreshold: blockDeltaThreshold
            )
            let elapsed = sample.time - last.time
            let changedPastSpacing = !sameScene && elapsed >= minEventInterval
            let hardCut = !sameScene && bits >= hardCutBitThreshold
            let silenceOver = elapsed >= maxSilenceInterval
            if changedPastSpacing || hardCut || silenceOver {
                result.append(SceneEvent(time: sample.time, signature: sample.signature))
                anchor = (sample.time, sample.signature)
            }
        }
        return result
    }

    /// 按**时间轴覆盖**分配代表帧名额：把 [0, span) 等分成 `limit` 个窗口，
    /// 每个窗口取权重最大、且**与已选帧都不是同一画面**的一个变化事件；
    /// 空窗口不占名额，省下的名额再按权重回填，同样受跨窗判重约束。
    ///
    /// 与旧的「按事件序号等间隔」相比，这里每个名额对应大致相等的一段视频，
    /// 画面变化密集的区段不会再挤掉长时间静止的幻灯片。
    ///
    /// 为什么必须跨窗判重：`sceneChangeTimes` 只与上一次已接受的参照帧比较，参照帧会随时间前移，
    /// 同一段静止内容在相隔几个窗口的两处各产生一个事件时，两个事件各自都与自己的参照帧不同、
    /// 却彼此相同；旧实现每窗各取一帧、窗口之间从不比较。实测 32 个名额里有 6 个是这种重复帧
    /// （最极端的一对只差 62 秒、合并位差 1），等于白丢 19% 的画面名额。
    static func selectRepresentativeTimes(
        events: [SceneEvent],
        duration: TimeInterval,
        limit: Int,
        bitThreshold: Int = duplicateBitThreshold,
        blockDeltaThreshold: Int = blockDeltaThreshold
    ) -> [TimeInterval] {
        guard limit > 0 else { return [] }
        let sorted = events.filter { $0.time.isFinite }.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return [] }
        // 事件没超出名额时全部保留（包括彼此重复的）：“有位置就都给”优先于跨窗判重，
        // 只有需要淘汰时才把重复帧换成真正不同的画面
        if sorted.count <= limit { return sorted.map(\.time) }

        // 覆盖到最后一个事件之后，保证权重与窗口编号对全部事件有定义
        let fallbackSpan = sorted[sorted.count - 1].time + 1
        let span = max(duration.isFinite ? duration : 0, fallbackSpan)

        // 事件的代表时间 ≈ 与左右相邻事件的中点间隔（两端补到 0 与 span）
        var weight: [TimeInterval] = []
        weight.reserveCapacity(sorted.count)
        for index in sorted.indices {
            let left = index == 0 ? 0 : (sorted[index].time + sorted[index - 1].time) / 2
            let right = index == sorted.count - 1 ? span : (sorted[index].time + sorted[index + 1].time) / 2
            weight.append(max(0, right - left))
        }

        let window = span / Double(limit)
        var buckets: [[Int]] = Array(repeating: [], count: limit)
        for index in sorted.indices {
            let bucket = min(max(Int(sorted[index].time / window), 0), limit - 1)
            buckets[bucket].append(index)
        }

        var picked: Set<Int> = []

        /// 与全部已选帧两两比较：只要有一对按 `isSameScene` 判为同一画面就不能再占名额。
        /// 必须与「已选集」比而不是只比前一个，否则锚点前移后同一段内容会反复入选。
        func conflictsWithPicked(_ candidate: Int) -> Bool {
            let signature = sorted[candidate].signature
            return picked.contains { index in
                isSameScene(
                    signature, asReferenceTo: sorted[index].signature,
                    bitThreshold: bitThreshold, blockDeltaThreshold: blockDeltaThreshold
                )
            }
        }
        /// 权重降序，并列时取更早的时间点，保证结果可重现
        func byWeight(_ lhs: Int, _ rhs: Int) -> Bool {
            if weight[lhs] != weight[rhs] { return weight[lhs] > weight[rhs] }
            return sorted[lhs].time < sorted[rhs].time
        }

        // 第一轮：每个非空窗口按权重降序取第一个「与已选画面都不同」的事件。
        // 整窗候选都跟已选重复时直接不占名额，把机会留给后面的回填轮。
        for bucket in buckets {
            guard let best = bucket.sorted(by: byWeight).first(where: { !conflictsWithPicked($0) }) else { continue }
            picked.insert(best)
        }
        // 第二轮：空窗口省下的名额按权重回填。判据是“画面是否重复”，不再是旧的“时间是否够远”：
        // 同一画面里的两个时间点必然靠得很近，用 `window/2` 的间距当门既挡掉真画面又填不满名额。
        // 入选只会让已选集变大、可入选集合单调缩小，所以按固定权重序单程遍历等价于逐轮取最大。
        for index in sorted.indices.sorted(by: byWeight) where picked.count < limit {
            guard !picked.contains(index), !conflictsWithPicked(index) else { continue }
            picked.insert(index)
        }
        return picked.map { sorted[$0].time }.sorted()
    }

    // MARK: - 纯函数：帧判重（差值哈希 + 分块亮度）

    /// 差值哈希：9×8 灰度网逐行比较左右相邻像素，`left < right` 置 1。
    /// 对整体缩放、亮度漂移、编码噪声稳定；输入长度不符时返回 nil（调用方按"无法判重"处理）
    static func dHash(fromLuminance gray: [UInt8],
                      width: Int = hashGridWidth,
                      height: Int = hashGridHeight) -> UInt64? {
        guard width >= 2, height >= 1, gray.count == width * height else { return nil }
        var hash: UInt64 = 0
        let bitsPerRow = width - 1
        for row in 0..<height {
            for column in 0..<bitsPerRow {
                let left = gray[row * width + column]
                let right = gray[row * width + column + 1]
                if left < right {
                    hash |= (1 << UInt64(row * bitsPerRow + column))
                }
            }
        }
        return hash
    }

    /// 上下路差值哈希：同一 9×8 网格逐列比较上下相邻像素，`upper < lower` 置 1。
    /// 补上水平方向哈希完全看不见的垂直变化（文档/代码滚动、逐行书写）。
    static func vHash(fromLuminance gray: [UInt8],
                      width: Int = hashGridWidth,
                      height: Int = hashGridHeight) -> UInt64? {
        guard width >= 1, height >= 2, gray.count == width * height else { return nil }
        var hash: UInt64 = 0
        var bit = 0
        for row in 0..<(height - 1) {
            for column in 0..<width {
                if gray[row * width + column] < gray[(row + 1) * width + column] {
                    hash |= (1 << UInt64(bit))
                }
                bit += 1
            }
        }
        return hash
    }

    /// 把 width×height 灰度均分成 blocksPerSide×blocksPerSide 块，返回每块平均亮度（行优先）。
    /// 尺寸不能整除时返回 nil（宁可算不出，也不给出看起来对但不可比的均值）。
    static func blockMeans(fromLuminance gray: [UInt8],
                           width: Int, height: Int,
                           blocksPerSide: Int = blockCountPerSide) -> [UInt8]? {
        guard width > 0, height > 0, blocksPerSide >= 1,
              gray.count == width * height,
              width % blocksPerSide == 0, height % blocksPerSide == 0
        else { return nil }
        let blockWidth = width / blocksPerSide
        let blockHeight = height / blocksPerSide
        var means: [UInt8] = []
        means.reserveCapacity(blocksPerSide * blocksPerSide)
        for blockRow in 0..<blocksPerSide {
            for blockColumn in 0..<blocksPerSide {
                var sum = 0
                var count = 0
                for row in (blockRow * blockHeight)..<((blockRow + 1) * blockHeight) {
                    for column in (blockColumn * blockWidth)..<((blockColumn + 1) * blockWidth) {
                        sum += Int(gray[row * width + column])
                        count += 1
                    }
                }
                means.append(count > 0 ? UInt8(sum / count) : 0)
            }
        }
        return means
    }

    /// 两个哈希的汉明距离（不同 bit 数）
    static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    /// 任意尺寸灰度网格的相邻比较位，按 64 bit 分词，供细节签名使用。
    static func packedDifferenceHash(
        fromLuminance gray: [UInt8],
        width: Int,
        height: Int,
        vertical: Bool
    ) -> [UInt64]? {
        guard width >= 2, height >= 2, gray.count == width * height else { return nil }
        let bitCount = vertical ? width * (height - 1) : (width - 1) * height
        var words = [UInt64](repeating: 0, count: (bitCount + 63) / 64)
        var bit = 0
        if vertical {
            for row in 0..<(height - 1) {
                for column in 0..<width {
                    if gray[row * width + column] < gray[(row + 1) * width + column] {
                        words[bit / 64] |= 1 << UInt64(bit % 64)
                    }
                    bit += 1
                }
            }
        } else {
            for row in 0..<height {
                for column in 0..<(width - 1) {
                    if gray[row * width + column] < gray[row * width + column + 1] {
                        words[bit / 64] |= 1 << UInt64(bit % 64)
                    }
                    bit += 1
                }
            }
        }
        return words
    }

    /// 两帧签名的合并位差（左右 64 bit + 上下 63 bit，最大 127）
    static func bitDistance(_ lhs: FrameSignature, _ rhs: FrameSignature) -> Int {
        hammingDistance(lhs.horizontal, rhs.horizontal)
            + hammingDistance(lhs.vertical, rhs.vertical)
    }

    static func detailBitDistance(_ lhs: FrameSignature, _ rhs: FrameSignature) -> Int {
        guard !lhs.detailHorizontal.isEmpty,
              lhs.detailHorizontal.count == rhs.detailHorizontal.count,
              lhs.detailVertical.count == rhs.detailVertical.count else { return 0 }
        let horizontal = zip(lhs.detailHorizontal, rhs.detailHorizontal)
            .reduce(0) { $0 + hammingDistance($1.0, $1.1) }
        let vertical = zip(lhs.detailVertical, rhs.detailVertical)
            .reduce(0) { $0 + hammingDistance($1.0, $1.1) }
        return horizontal + vertical
    }

    /// 两帧签名的分块平均亮度最大偏差（0...255）；块数不一致时返回满量程，按“有变化”处理
    static func maxBlockDelta(_ lhs: FrameSignature, _ rhs: FrameSignature) -> Int {
        guard !lhs.blockMeans.isEmpty, lhs.blockMeans.count == rhs.blockMeans.count else { return 255 }
        return zip(lhs.blockMeans, rhs.blockMeans).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    /// 分块 RGB 最大偏差；任一侧没有颜色特征时返回 0，兼容纯函数测试构造的旧式签名。
    static func maxColorBlockDelta(_ lhs: FrameSignature, _ rhs: FrameSignature) -> Int {
        guard !lhs.colorBlockMeans.isEmpty,
              lhs.colorBlockMeans.count == rhs.colorBlockMeans.count else { return 0 }
        return zip(lhs.colorBlockMeans, rhs.colorBlockMeans)
            .map { abs(Int($0) - Int($1)) }
            .max() ?? 0
    }

    /// 同一画面判定：两路结构位差够近 **且** 没有任何分块亮度显著变化，才算重复。
    /// 两门缺一都会重现原缺陷：只看位差会把换色/纯色淡入淡出误判为重复，
    /// 只看亮度会放过“明暗方向变了但整体亮度没变”的真实画面变化。
    static func isSameScene(_ sample: FrameSignature,
                            asReferenceTo reference: FrameSignature,
                            bitThreshold: Int = duplicateBitThreshold,
                            blockDeltaThreshold: Int = blockDeltaThreshold) -> Bool {
        bitDistance(sample, reference) <= bitThreshold
            && detailBitDistance(sample, reference) <= detailDuplicateBitThreshold
            && maxBlockDelta(sample, reference) <= blockDeltaThreshold
            && maxColorBlockDelta(sample, reference) <= colorBlockDeltaThreshold
    }

    // MARK: - 抽帧

    /// 抽取去重后的关键帧（按时间升序）
    /// - Parameters:
    ///   - videoURL: 导入时留存的原始视频（`{base}_video.{ext}`）
    ///   - maxFrames: 显式安全上限；传 nil 时保留全部稳定重大变化，极端素材最多 `maxKeyframes`
    ///   - scanInterval: 低分辨率扫描间隔下限（秒）；超长视频会按点数上限自动放宽
    ///   - onProgress: 0...1 进度回调（抽帧天然逐帧，粒度足够）
    static func extractKeyframes(
        from videoURL: URL,
        maxFrames: Int? = nil,
        scanInterval requestedScanInterval: TimeInterval = defaultScanInterval,
        onProgress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> [VideoKeyframe] {
        let asset = AVURLAsset(url: videoURL)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard duration > 0, !videoTracks.isEmpty else {
            throw KeyframeError.unreadableVideo
        }

        let safetyLimit = maxFrames ?? maxKeyframes
        let adaptiveScanInterval = scanInterval(
            forDuration: duration,
            minimum: requestedScanInterval
        )
        guard safetyLimit > 0, adaptiveScanInterval > 0 else { throw KeyframeError.noKeyframe }

        let candidates = scanTimes(duration: duration, interval: adaptiveScanInterval)
        let scanGenerator = makeGenerator(
            asset: asset,
            pixelSize: scanPixelSize,
            tolerance: min(adaptiveScanInterval / 4, 0.1)
        )
        var scannedSamples: [(time: TimeInterval, signature: FrameSignature)] = []
        var firstSample: SceneEvent?
        var processedCount = 0

        // AVAssetImageGenerator 的多时间点接口会按时间顺序批量解码，比逐点随机 seek 更适合高频扫描。
        for batchStart in stride(from: 0, to: candidates.count, by: scanBatchSize) {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + scanBatchSize, candidates.count)
            let requestedTimes = candidates[batchStart..<batchEnd].map {
                CMTime(seconds: $0, preferredTimescale: 600)
            }
            for await result in scanGenerator.images(for: requestedTimes) {
                try Task.checkCancellation()
                defer {
                    processedCount += 1
                    onProgress(Double(processedCount) / Double(max(candidates.count, 1)) * 0.8)
                }
                guard case let .success(requestedTime, image, _) = result else { continue }
                let seconds = CMTimeGetSeconds(requestedTime)
                if let signature = signature(of: image) {
                    scannedSamples.append((time: seconds, signature: signature))
                    if firstSample == nil { firstSample = SceneEvent(time: seconds, signature: signature) }
                }
            }
        }

        var changedEvents = sceneChangeTimes(from: scannedSamples)
        if changedEvents.isEmpty, let firstSample {
            changedEvents = [firstSample]
        }
        let significantEvents = significantSceneEvents(from: changedEvents)
        let selectedTimes = selectTimelineCoverageTimes(
            events: significantEvents,
            duration: duration,
            limit: safetyLimit
        )

        let fullSizeGenerator = makeGenerator(
            asset: asset,
            pixelSize: maxPixelSize,
            tolerance: min(adaptiveScanInterval / 4, 0.1)
        )
        let requestedTimes = selectedTimes.map { CMTime(seconds: $0, preferredTimescale: 600) }
        var frames: [VideoKeyframe] = []
        var fullSizeProcessedCount = 0
        for await result in fullSizeGenerator.images(for: requestedTimes) {
            try Task.checkCancellation()
            defer {
                fullSizeProcessedCount += 1
                onProgress(0.8 + Double(fullSizeProcessedCount) / Double(max(selectedTimes.count, 1)) * 0.2)
            }
            guard case let .success(requestedTime, image, _) = result,
                  let jpeg = encodeJPEG(image) else { continue }
            frames.append(VideoKeyframe(time: CMTimeGetSeconds(requestedTime), jpegData: jpeg))
        }
        frames.sort { $0.time < $1.time }

        guard !frames.isEmpty else {
            throw KeyframeError.noKeyframe
        }
        logger.info("关键帧抽取完成：间隔 \(adaptiveScanInterval, format: .fixed(precision: 2))s 扫描 \(candidates.count) 点，检测 \(changedEvents.count) 次画面变化，稳定重大变化 \(significantEvents.count) 次，安全上限 \(safetyLimit)，保留 \(frames.count) 帧，来源 \(videoURL.lastPathComponent)")
        return frames
    }

    private static func makeGenerator(
        asset: AVAsset,
        pixelSize: CGFloat,
        tolerance: TimeInterval
    ) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixelSize, height: pixelSize)
        let requestedTolerance = CMTime(seconds: tolerance, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = requestedTolerance
        generator.requestedTimeToleranceAfter = requestedTolerance
        return generator
    }

    // MARK: - 内部：像素工具

    /// 帧 → 画面签名（9×8 网格出左右/上下两路差值哈希，24×24 网格出 3×3 分块亮度均值）
    static func signature(of image: CGImage) -> FrameSignature? {
        guard let grid = luminance(of: image, width: hashGridWidth, height: hashGridHeight),
              let horizontal = dHash(fromLuminance: grid),
              let vertical = vHash(fromLuminance: grid),
              let detailGrid = luminance(
                of: image, width: detailHashGridWidth, height: detailHashGridHeight
              ),
              let detailHorizontal = packedDifferenceHash(
                fromLuminance: detailGrid,
                width: detailHashGridWidth,
                height: detailHashGridHeight,
                vertical: false
              ),
              let detailVertical = packedDifferenceHash(
                fromLuminance: detailGrid,
                width: detailHashGridWidth,
                height: detailHashGridHeight,
                vertical: true
              ),
              let sample = luminance(of: image, width: blockSampleSide, height: blockSampleSide),
              let means = blockMeans(fromLuminance: sample, width: blockSampleSide, height: blockSampleSide),
              let colorMeans = colorBlockMeans(of: image)
        else { return nil }
        return FrameSignature(
            horizontal: horizontal,
            vertical: vertical,
            blockMeans: means,
            colorBlockMeans: colorMeans,
            detailHorizontal: detailHorizontal,
            detailVertical: detailVertical
        )
    }

    /// CGImage → JPEG（ImageIO，无 AppKit 绘图状态依赖，可安全在后台线程调用）
    static func encodeJPEG(_ image: CGImage, quality: Float = jpegQuality) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return output as Data
    }

    /// 缩放到 width×height 并转 BT.601 整数近似亮度（Rec.601：0.299R+0.587G+0.114B）
    private static func luminance(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buffer = context.data else { return nil }

        let pixels = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var gray = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let red = UInt32(pixels[index * 4])
            let green = UInt32(pixels[index * 4 + 1])
            let blue = UInt32(pixels[index * 4 + 2])
            gray[index] = UInt8((red &* 30 + green &* 59 + blue &* 11) / 100)
        }
        return gray
    }

    /// 24×24 RGB 缓冲按 3×3 分块取每通道均值，补足灰度哈希看不见的色相变化。
    private static func colorBlockMeans(of image: CGImage) -> [UInt8]? {
        let side = blockSampleSide
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }

        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        let blockSide = side / blockCountPerSide
        var result: [UInt8] = []
        result.reserveCapacity(blockCountPerSide * blockCountPerSide * 3)
        for blockRow in 0..<blockCountPerSide {
            for blockColumn in 0..<blockCountPerSide {
                var red = 0
                var green = 0
                var blue = 0
                var count = 0
                for row in (blockRow * blockSide)..<((blockRow + 1) * blockSide) {
                    for column in (blockColumn * blockSide)..<((blockColumn + 1) * blockSide) {
                        let offset = (row * side + column) * 4
                        red += Int(pixels[offset])
                        green += Int(pixels[offset + 1])
                        blue += Int(pixels[offset + 2])
                        count += 1
                    }
                }
                result.append(UInt8(red / count))
                result.append(UInt8(green / count))
                result.append(UInt8(blue / count))
            }
        }
        return result
    }
}
