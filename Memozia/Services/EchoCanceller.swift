import Accelerate
import Foundation

/// 离线参考回声消除（AEC）配置。
///
/// 场景：会议软件的声音从本地扬声器放出，又被本地麦克风采回去，于是远端的话
/// 在「麦克风轨」和「系统音轨」各有一份。本处理器以**系统音轨为参考**、以
/// **麦克风轨为目标**，把麦克风轨里属于系统音轨的那部分减掉。
///
/// 注意：这不处理「自己声音绕网络回来」的那条路径（远端编码与网络抖动使其
/// 无法用线性滤波建模），那条路径由双轨分离转写去重解决。
struct EchoCancellerConfig: Sendable {
    /// 分块长度，同时也是自适应滤波器可建模的回声尾长（样本数）。
    /// 4096 @48kHz ≈ 85ms，覆盖扬声器 → 麦克风的直达声与早期反射。
    var blockSize: Int
    /// 归一化步长。
    var stepSize: Float
    /// 每 bin 功率归一化的正则项，避免静音段把噪声放大成更新量。
    var regularization: Float
    /// 双讲冻结阈值：本块「麦克风能量 / 参考能量」超过该比值即判定本地语音主导，
    /// 冻结权重更新，避免把用户本人的声音当成回声消掉。
    /// 成立前提是回声路径有衰减（回声返回损耗通常 ≥6dB），若扬声器音量极大且
    /// 麦克风贴近扬声器，可能一直冻结——此时回退为不处理，不会产生更差的结果。
    var localSpeechFreezeRatio: Float

    init(
        blockSize: Int = 4096,
        stepSize: Float = 0.3,
        regularization: Float = 1e-3,
        localSpeechFreezeRatio: Float = 1.0
    ) {
        self.blockSize = blockSize
        self.stepSize = stepSize
        self.regularization = regularization
        self.localSpeechFreezeRatio = localSpeechFreezeRatio
    }
}

/// 离线回声消除核心（纯信号处理，不涉及文件与容器）。
///
/// 全部输入输出都是**同一采样率的单声道 Float32 PCM**；采样率由调用方保证，
/// 本模块只关心时间对齐与自适应滤波。刻意不依赖 AVFoundation，便于单元测试。
enum EchoCanceller {

    // MARK: - 延迟估计

    /// 估计「参考信号领先麦克风信号」的样本数。
    ///
    /// 定义：返回 `lag` 时表示 `mic[n] ≈ reference[n - lag]`（`lag` 为正是参考领先）。
    /// 该值同时吸收了三个来源：两路采集的**启动时间差**、扬声器到麦克风的**声学延迟**、
    /// 以及会议软件自身的播放缓冲。因此必须实测而非假定为 0。
    ///
    /// 实现：先在 ~12kHz 上做归一化互相关粗搜（把成本压到不依赖原始采样率），
    /// 再在粗结果 ±抽取倍数内用原始采样率精修。
    ///
    /// - Returns: 延迟样本数；信号过短、全程静音或相关性过低时返回 nil。
    static func estimateDelay(
        mic: [Float],
        reference: [Float],
        sampleRate: Double,
        maxDelaySeconds: Double = 1.5,
        windowSeconds: Double = 4.0,
        minCorrelation: Float = 0.05
    ) -> Int? {
        guard sampleRate > 0, !mic.isEmpty, !reference.isEmpty else { return nil }

        // 抽取到约 12kHz：互相关是 O(窗口 × 迟滞范围)，在原采样率上做会随采样率线性变慢，
        // 而 ms 级精度只需 12kHz（1 样本 ≈ 83µs），后续再精修回原采样率。
        let decimation = max(1, Int((sampleRate / 12_000).rounded()))
        let micDec = decimate(mic, by: decimation)
        let refDec = decimate(reference, by: decimation)
        let decimatedRate = sampleRate / Double(decimation)

        let windowLength = min(
            Int(windowSeconds * decimatedRate),
            min(micDec.count, refDec.count) / 2
        )
        guard windowLength >= 64 else { return nil }

        let maxLag = min(
            Int(maxDelaySeconds * decimatedRate),
            min(micDec.count, refDec.count) - windowLength
        )
        guard maxLag > 0 else { return nil }

        // 在麦克风上取能量最高的窗口做分析（窗口决定相关性质量，静音窗没有信息量）。
        // 两路是同一时刻开始录的，绝对索引大致对齐，故参考侧用同一索引。
        let micStart = maxEnergyWindowStart(micDec, windowLength: windowLength)
        let micWindow = micDec[micStart..<(micStart + windowLength)]
        let micEnergy = sumOfSquares(micWindow)
        guard micEnergy > 0 else { return nil }

        // 参考侧可用索引范围受窗口与边界共同约束，取与 [-maxLag, maxLag] 的交集
        let lowerLag = max(-maxLag, micStart - (refDec.count - windowLength))
        let upperLag = min(maxLag, micStart)
        guard lowerLag <= upperLag else { return nil }

        var bestLag = 0
        var bestScore: Float = 0
        for lag in lowerLag...upperLag {
            let refStart = micStart - lag
            let refWindow = refDec[refStart..<(refStart + windowLength)]
            let refEnergy = sumOfSquares(refWindow)
            guard refEnergy > 0 else { continue }
            let correlation = dot(micWindow, refWindow)
            // 归一化：消除两路增益差的影响，只保留形状相似度
            let score = correlation / (micEnergy * refEnergy).squareRoot()
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        guard bestScore >= minCorrelation else { return nil }

        // 精修：在抽取尺度结果的 ±decimation 内用原始采样率复算
        let coarseLag = bestLag * decimation
        var fineLag = coarseLag
        var fineScore: Float = -1
        if decimation > 1 {
            for candidate in (coarseLag - decimation)...(coarseLag + decimation) {
                if let score = normalizedCorrelation(mic: mic, reference: reference, lag: candidate) {
                    if score > fineScore {
                        fineScore = score
                        fineLag = candidate
                    }
                }
            }
        }
        return fineLag
    }

    /// 在原始采样率上计算某个 lag 的归一化互相关（用于精修）。
    private static func normalizedCorrelation(mic: [Float], reference: [Float], lag: Int) -> Float? {
        // 取一段位于两路都有效范围内的窗口
        let window = min(Int(0.5 * 48_000), min(mic.count, reference.count) / 4)
        guard window >= 64 else { return nil }
        // 让参考窗口居中于有效区间，避免边界处的部分零填充污染相关性
        let micStart = min(mic.count - window, max(0, (mic.count - window) / 2))
        let refStart = micStart - lag
        guard refStart >= 0, refStart + window <= reference.count, micStart >= 0 else { return nil }
        let micWindow = mic[micStart..<(micStart + window)]
        let refWindow = reference[refStart..<(refStart + window)]
        let micEnergy = sumOfSquares(micWindow)
        let refEnergy = sumOfSquares(refWindow)
        guard micEnergy > 0, refEnergy > 0 else { return nil }
        return dot(micWindow, refWindow) / (micEnergy * refEnergy).squareRoot()
    }

    // MARK: - 对齐与离线处理

    /// 把参考信号按延迟平移，使 `aligned[n] = reference[n - delay]`。
    /// 延迟为正时在头部补零，为负时丢弃参考开头。
    static func alignReference(_ reference: [Float], delay: Int) -> [Float] {
        guard delay != 0 else { return reference }
        if delay > 0 {
            var aligned = [Float](repeating: 0, count: delay + reference.count)
            aligned.replaceSubrange(delay..<(delay + reference.count), with: reference)
            return aligned
        }
        let skip = min(-delay, reference.count)
        return Array(reference.dropFirst(skip))
    }

    /// 一次性处理整段音频（测试与短片段便利入口）。
    ///
    /// 长音频请直接用 `FrequencyDomainAdaptiveFilter` 分块流式处理，
    /// 避免把整段录音读进内存。
    static func cancel(
        mic: [Float],
        reference: [Float],
        delay: Int,
        config: EchoCancellerConfig = EchoCancellerConfig()
    ) -> [Float] {
        guard let filter = FrequencyDomainAdaptiveFilter(config: config) else { return mic }
        let aligned = alignReference(reference, delay: delay)
        let block = filter.blockSize

        var output = [Float](repeating: 0, count: mic.count)
        var micBlock = [Float](repeating: 0, count: block)
        var refBlock = [Float](repeating: 0, count: block)
        var outBlock = [Float](repeating: 0, count: block)

        var index = 0
        while index < mic.count {
            let count = min(block, mic.count - index)
            for i in 0..<block {
                micBlock[i] = i < count ? mic[index + i] : 0
                refBlock[i] = (index + i) < aligned.count ? aligned[index + i] : 0
            }
            filter.process(
                micBlock: micBlock, referenceBlock: refBlock, into: &outBlock, count: block
            )
            for i in 0..<count { output[index + i] = outBlock[i] }
            index += count
        }
        return output
    }

    // MARK: - 私有工具

    /// 按整数倍平均抽取（兼作粗糙抗混叠），仅用于延迟粗搜。
    private static func decimate(_ input: [Float], by factor: Int) -> [Float] {
        guard factor > 1 else { return input }
        let count = input.count / factor
        guard count > 0 else { return [] }
        var output = [Float](repeating: 0, count: count)
        let scale = 1 / Float(factor)
        for i in 0..<count {
            var sum: Float = 0
            let base = i * factor
            for j in 0..<factor { sum += input[base + j] }
            output[i] = sum * scale
        }
        return output
    }

    /// 在允许范围内找能量最高的窗口起点。
    private static func maxEnergyWindowStart(_ signal: [Float], windowLength: Int) -> Int {
        let limit = signal.count - windowLength
        guard limit > 0 else { return 0 }
        let stride = max(1, windowLength / 4)
        var bestStart = 0
        var bestEnergy: Float = -1
        var start = 0
        while start <= limit {
            let energy = sumOfSquares(signal[start..<(start + windowLength)])
            if energy > bestEnergy {
                bestEnergy = energy
                bestStart = start
            }
            start += stride
        }
        return bestStart
    }

    private static func dot(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var result: Float = 0
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                vDSP_dotpr(ap.baseAddress!, 1, bp.baseAddress!, 1, &result, vDSP_Length(a.count))
            }
        }
        return result
    }

    static func sumOfSquares(_ a: ArraySlice<Float>) -> Float {
        guard !a.isEmpty else { return 0 }
        var result: Float = 0
        a.withUnsafeBufferPointer { ap in
            vDSP_svesq(ap.baseAddress!, 1, &result, vDSP_Length(a.count))
        }
        return result
    }
}

/// 分块频域自适应滤波器（约束式 overlap-save 频域 NLMS）。
///
/// 为什么用频域：时域自适应 FIR 对 4096 抽头的计算量是 O(抽头数) 每采样，
/// 一小时素材无法接受；频域每块只需常数次 FFT。
///
/// 结构：窗口长度 = 2 × blockSize（overlap-save 的 50% 重叠），权重向量与窗口等长，
/// 因此可建模的回声尾长就等于 `blockSize`。
///
/// 线程约定：内部持有 FFT setup 与原始指针，**非 Sendable**，只能在单一执行域内
/// 串行使用（创建与使用都在同一任务里），不得跨 actor 传递。
final class FrequencyDomainAdaptiveFilter {

    private enum Slot: Int, CaseIterable {
        case inputReal, inputImag          // 输入窗（原地变为其频谱 X）
        case weightReal, weightImag        // 自适应权重 W（跨块保持）
        case productReal, productImag      // X⊙W（原地变为时域输出）
        case errorReal, errorImag          // 误差谱 E
        case power, magnitude              // 平滑功率谱 / |X|² 暂存
        case gradientReal, gradientImag    // 归一化梯度暂存
    }

    let blockSize: Int

    private let config: EchoCancellerConfig
    private let fftSize: Int
    private let log2FFTSize: vDSP_Length
    private let setup: FFTSetup
    /// 全部频域缓冲：一次分配，按槽位偏移切分，避免每块重复分配（一小时素材数万块）
    private let buffer: UnsafeMutablePointer<Float>
    /// overlap-save 需要的前一块参考样本
    private let previousInput: UnsafeMutablePointer<Float>

    /// 创建失败（FFT setup 无法建立）时返回 nil，调用方回退为不处理原始音频。
    init?(config: EchoCancellerConfig) {
        // 归一化到 2 的幂：overlap-save 的窗口必须是 2 的幂才能用基-2 FFT
        let requested = max(256, config.blockSize)
        let exponent = Int(log2(Double(requested)).rounded())
        let block = 1 << exponent
        self.config = config
        self.blockSize = block
        self.fftSize = block * 2
        self.log2FFTSize = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2FFTSize, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        self.setup = setup
        self.buffer = UnsafeMutablePointer<Float>.allocate(capacity: Slot.allCases.count * fftSize)
        self.buffer.initialize(repeating: 0, count: Slot.allCases.count * fftSize)
        self.previousInput = UnsafeMutablePointer<Float>.allocate(capacity: block)
        self.previousInput.initialize(repeating: 0, count: block)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        buffer.deinitialize(count: Slot.allCases.count * fftSize)
        buffer.deallocate()
        previousInput.deinitialize(count: blockSize)
        previousInput.deallocate()
    }

    private func pointer(_ slot: Slot) -> UnsafeMutablePointer<Float> {
        buffer + slot.rawValue * fftSize
    }

    /// 处理一块：输入麦克风块与（已按时延对齐的）参考块，输出消除回声后的麦克风块。
    /// - Parameters:
    ///   - count: 有效样本数；不足一块时尾部按零填充处理。
    func process(
        micBlock: [Float],
        referenceBlock: [Float],
        into output: inout [Float],
        count: Int
    ) {
        micBlock.withUnsafeBufferPointer { mic in
            referenceBlock.withUnsafeBufferPointer { reference in
                output.withUnsafeMutableBufferPointer { out in
                    process(
                        micBlock: mic.baseAddress!,
                        referenceBlock: reference.baseAddress!,
                        output: out.baseAddress!,
                        count: count
                    )
                }
            }
        }
    }

    /// 指针版本入口（供流式读取时避免中间数组拷贝）
    func process(
        micBlock: UnsafePointer<Float>,
        referenceBlock: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        count: Int
    ) {
        let n = fftSize
        let half = blockSize
        let bytes = MemoryLayout<Float>.size

        let inputReal = pointer(.inputReal), inputImag = pointer(.inputImag)
        let weightReal = pointer(.weightReal), weightImag = pointer(.weightImag)
        let productReal = pointer(.productReal), productImag = pointer(.productImag)
        let errorReal = pointer(.errorReal), errorImag = pointer(.errorImag)
        let power = pointer(.power), magnitude = pointer(.magnitude)
        let gradientReal = pointer(.gradientReal), gradientImag = pointer(.gradientImag)

        // 1. overlap-save 输入窗：[上一块参考, 当前参考]
        memcpy(inputReal, previousInput, half * bytes)
        memcpy(inputReal + half, referenceBlock, half * bytes)
        memset(inputImag, 0, n * bytes)
        memcpy(previousInput, referenceBlock, half * bytes)

        // 2. X = FFT(窗)
        var inputSplit = DSPSplitComplex(realp: inputReal, imagp: inputImag)
        var weightSplit = DSPSplitComplex(realp: weightReal, imagp: weightImag)
        var productSplit = DSPSplitComplex(realp: productReal, imagp: productImag)
        var errorSplit = DSPSplitComplex(realp: errorReal, imagp: errorImag)
        var gradientSplit = DSPSplitComplex(realp: gradientReal, imagp: gradientImag)
        vDSP_fft_zip(setup, &inputSplit, 1, log2FFTSize, FFTDirection(FFT_FORWARD))

        // 3. Y = X ⊙ W
        vDSP_zvmul(&inputSplit, 1, &weightSplit, 1, &productSplit, 1, vDSP_Length(n), 0)

        // 4. y = IFFT(Y) / n；取后半段为有效线性卷积结果（前半为圆周卷积污染）
        vDSP_fft_zip(setup, &productSplit, 1, log2FFTSize, FFTDirection(FFT_INVERSE))
        var inverseScale = 1 / Float(n)
        vDSP_vsmul(productReal, 1, &inverseScale, productReal, 1, vDSP_Length(n))

        // 5. e = 麦克风 - 回声估计
        var minusOne: Float = -1
        vDSP_vsma(productReal + half, 1, &minusOne, micBlock, 1, output, 1, vDSP_Length(half))
        // 尾部不足一块时输出会包含补零段的产物，超出 count 的部分由调用方忽略

        // 6. 双讲判定：本地语音主导时冻结更新
        let micEnergy = sumOfSquares(micBlock, count)
        let referenceEnergy = sumOfSquares(referenceBlock, half)
        let referenceFloor: Float = 1e-9
        let adapt = referenceEnergy > referenceFloor
            && micEnergy <= config.localSpeechFreezeRatio * referenceEnergy
        guard adapt else { return }

        // 7. E = FFT([0; e])
        memset(errorReal, 0, half * bytes)
        memcpy(errorReal + half, output, half * bytes)
        memset(errorImag, 0, n * bytes)
        vDSP_fft_zip(setup, &errorSplit, 1, log2FFTSize, FFTDirection(FFT_FORWARD))

        // 8. 功率谱平滑（指数平均）：瞬时 |X|² 方差太大，直接用会让权重抖动
        vDSP_zvmags(&inputSplit, 1, magnitude, 1, vDSP_Length(n))
        var decay: Float = 0.9
        var growth: Float = 0.1
        vDSP_vsmul(power, 1, &decay, power, 1, vDSP_Length(n))
        vDSP_vsma(magnitude, 1, &growth, power, 1, power, 1, vDSP_Length(n))

        // 9. 梯度 = conj(X) ⊙ E（频域）
        // 注意 vDSP_zvmul 的 Conjugate 取 -1 才是 conj(A)·B（+1 表示不做共轭），
        // 少了共轭会让相位反号，权重越更新越偏、直接发散。
        vDSP_zvmul(&inputSplit, 1, &errorSplit, 1, &gradientSplit, 1, vDSP_Length(n), -1)

        // 10. per-bin 归一化：除以平滑功率谱（加正则项），等效于逐 bin 的 NLMS。
        // 必须排在约束之前——约束会把每个 bin 的更新摊到全部 bin 上，之后再除以
        // 能量极低的 bin 功率，放大量会达到 1/regularization 量级并直接发散。
        var regularization = config.regularization
        vDSP_vsadd(power, 1, &regularization, magnitude, 1, vDSP_Length(n))
        // vDSP_vdiv 的形参顺序与算式相反：头文件声明为 (B, A, C) 且算式是 C = A / B，
        // 所以「第一个参数是分母、第二个参数是分子」，写反会变成 0 除 0 直接产出 inf/nan。
        vDSP_vdiv(magnitude, 1, gradientReal, 1, gradientReal, 1, vDSP_Length(n))
        vDSP_vdiv(magnitude, 1, gradientImag, 1, gradientImag, 1, vDSP_Length(n))

        // 11. 梯度约束：变换回时域后砍掉后半段（只保留前 blockSize 个抽头）再变换回频域。
        // 不做这一步就是「无约束 FDAF」——窗口长度是抽头数的两倍，更新量里含有圆周
        // 卷积的伪分量，会持续注入误差导致稳态失调大（实测 ERLE 停在约 9dB 不再改善）。
        // 约束后权重始终对应一个 blockSize 抽头的因果滤波器。
        // 约定核对：以 conj(X)⊙E 做 IFFT，前 blockSize 个样本正是
        // Σₙ e[n]·x[n-l]（l = 0…blockSize-1）的因果梯度，后半段是伪分量。
        vDSP_fft_zip(setup, &gradientSplit, 1, log2FFTSize, FFTDirection(FFT_INVERSE))
        vDSP_vsmul(gradientReal, 1, &inverseScale, gradientReal, 1, vDSP_Length(n))
        vDSP_vsmul(gradientImag, 1, &inverseScale, gradientImag, 1, vDSP_Length(n))
        memset(gradientReal + half, 0, half * bytes)
        memset(gradientImag + half, 0, half * bytes)
        vDSP_fft_zip(setup, &gradientSplit, 1, log2FFTSize, FFTDirection(FFT_FORWARD))

        // 12. 权重累加
        var stepSize = config.stepSize
        vDSP_vsma(gradientReal, 1, &stepSize, weightReal, 1, weightReal, 1, vDSP_Length(n))
        vDSP_vsma(gradientImag, 1, &stepSize, weightImag, 1, weightImag, 1, vDSP_Length(n))
    }

    private func sumOfSquares(_ a: UnsafePointer<Float>, _ count: Int) -> Float {
        guard count > 0 else { return 0 }
        var result: Float = 0
        vDSP_svesq(a, 1, &result, vDSP_Length(count))
        return result
    }
}