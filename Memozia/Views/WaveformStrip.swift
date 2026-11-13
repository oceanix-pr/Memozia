import SwiftUI

/// 播放条下方的声波图：横向铺满，纵向是「每列峰值」。
///
/// 用途是让人一眼看出**哪里有声音、哪里没有**：
/// - 有声处画成实心竖条，静音处只留一条淡淡的基线；
/// - 已播放部分用主题色，未播放部分用次级灰；
/// - 一条竖线标出当前播放位置，点击/拖动任意位置即跳转。
///
/// 视图只读取 `state.currentTime`（0.5s 一次），因此它自成一个子视图，
/// 不会把 `RecordingDetailView` 的整棵树卷进高频刷新。
struct WaveformStrip: View {
    let state: AudioPlayerState
    /// 已解析的声波包络；nil 时由 isLoading 区分分析中和读取失败
    let waveform: AudioWaveform?
    let isLoading: Bool

    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    /// 声波区高度（含上下留白）
    private let height: CGFloat = 34

    private var duration: TimeInterval {
        state.duration > 0 ? state.duration : 0
    }

    /// 拖动时优先显示拖动位置，松手后回到真实播放时间
    private var displayTime: TimeInterval {
        isScrubbing ? scrubTime : state.currentTime
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let progress = duration > 0 ? min(1, max(0, displayTime / duration)) : 0

            ZStack(alignment: .leading) {
                // 静音基线：即使整段没有声音，也能看出时间轴的长度
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 1.5)

                if let peaks = waveform?.peaks, !peaks.isEmpty {
                    Canvas { context, size in
                        draw(peaks: peaks, progress: progress, in: &context, size: size)
                    }
                } else if isLoading {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("声波分析中")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                } else {
                    Text("声波图不可用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                // 播放位置指示线
                if duration > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 1.5, height: height)
                        .offset(x: min(width - 1.5, max(0, width * progress)))
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        isScrubbing = true
                        scrubTime = time(atX: value.location.x, width: width)
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        let target = time(atX: value.location.x, width: width)
                        isScrubbing = false
                        state.seek(to: target)
                    }
            )
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(Text("声波图"))
        .accessibilityValue(Text(soundDescription))
        .accessibilityHint(Text("点击或拖动可跳转播放位置"))
        .accessibilityAdjustableAction { direction in
            guard duration > 0 else { return }
            let step = max(1, duration / 100)
            switch direction {
            case .increment:
                state.seek(to: min(duration, state.currentTime + step))
            case .decrement:
                state.seek(to: max(0, state.currentTime - step))
            @unknown default:
                break
            }
        }
    }

    /// 点击位置换算成秒，并夹在 0...duration 内
    private func time(atX x: CGFloat, width: CGFloat) -> TimeInterval {
        let ratio = min(1, max(0, x / width))
        return duration * Double(ratio)
    }

    /// 无障碍描述：说明这段录音里有多少比例是有声音的
    private var soundDescription: String {
        guard let peaks = waveform?.peaks, !peaks.isEmpty else {
            return isLoading ? String(localized: "声波分析中") : String(localized: "声波图不可用")
        }
        let audible = peaks.reduce(into: 0) { count, peak in
            if peak > WaveformAnalyzer.silenceThreshold { count += 1 }
        }
        let percent = Int((Double(audible) / Double(peaks.count) * 100).rounded())
        return String(format: String(localized: "约 %d%% 的时长有声音"), percent)
    }

    /// 逐列画竖条：有声处按峰值高度绘制，静音处几乎不画（只留基线）
    private func draw(peaks: [Float], progress: Double, in context: inout GraphicsContext, size: CGSize) {
        let columnCount = peaks.count
        guard columnCount > 0, size.width > 0 else { return }

        let slot = size.width / CGFloat(columnCount)
        // 列数很多时条宽不足 1pt，取 1pt 并允许轻微重叠，避免出现空隙导致「虚假静音」
        let barWidth = max(1, slot * 0.72)
        let midY = size.height / 2
        let maxHalf = max(1, size.height / 2 - 1)
        let playedColor = Color.accentColor
        let pendingColor = Color.secondary.opacity(0.45)
        let progressX = size.width * CGFloat(min(1, max(0, progress)))

        for index in 0..<columnCount {
            let peak = peaks[index]
            // 静音列不画竖条（只保留贯穿全宽的基线），让「没声音」一眼可辨
            guard peak > WaveformAnalyzer.silenceThreshold else { continue }

            let x = slot * CGFloat(index)
            // 峰值太小也留 1.5pt，保证「有声音」的地方一定能看到
            let halfHeight = max(1.5, CGFloat(peak) * maxHalf)
            let rect = CGRect(
                x: x,
                y: midY - halfHeight,
                width: barWidth,
                height: halfHeight * 2
            )
            let color = x + barWidth / 2 <= progressX ? playedColor : pendingColor
            context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
        }
    }
}
