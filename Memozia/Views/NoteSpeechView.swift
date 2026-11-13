import SwiftUI

/// 内容快照只读；音频仅放在临时目录，明确导出后才写入用户指定位置。
struct NoteSpeechView: View {
    @State private var model: NoteSpeechViewModel
    @Environment(\.dismiss) private var dismiss

    init(input: SpeechNoteInput) {
        _model = State(initialValue: NoteSpeechViewModel(input: input))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("转为语音", systemImage: "speaker.wave.2")
                    .font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Text(model.input.title).font(.headline).lineLimit(2)
            Text("使用 macOS 系统音色在本机合成，文字不会发送到云端。")
                .font(.callout).foregroundStyle(.secondary)

            Form {
                Picker("朗读内容", selection: $model.useSummary) {
                    Text("笔记正文").tag(false)
                        .disabled(model.input.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("已有总结").tag(true)
                        .disabled(model.input.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Picker("语言与地区", selection: $model.language) {
                    ForEach(model.languages, id: \.self) { language in
                        Text(SpeechVoiceOption.languageName(language)).tag(language)
                    }
                }
                .onChange(of: model.language) { _, _ in model.selectVoice() }
                HStack {
                    Picker("系统音色", selection: $model.voiceID) {
                        ForEach(model.filteredVoices) { voice in
                            Text(voice.displayName).tag(voice.id)
                        }
                    }
                    Button("刷新音色") { model.refreshVoices() }
                        .controlSize(.small)
                }
                HStack {
                    Slider(value: $model.speed, in: 0.6...1.4, step: 0.1) { Text("语速") }
                    Text(model.speed, format: .number.precision(.fractionLength(1)))
                        .monospacedDigit().frame(width: 36)
                }
                Picker("导出格式", selection: $model.format) {
                    ForEach(SpeechAudioFormat.allCases) { format in
                        Text(format.label).tag(format)
                            .disabled(format == .mp3 && !model.supportsMP3)
                    }
                }
            }
            .disabled(model.isBusy)
            .onChange(of: model.voiceID) { _, _ in model.invalidate() }
            .onChange(of: model.speed) { _, _ in model.invalidate() }
            .onChange(of: model.format) { _, _ in model.invalidate() }

            if model.voices.isEmpty {
                Text("没有可用的系统音色。请在系统设置的辅助功能语音选项中下载音色，再刷新列表。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !model.supportsMP3 {
                Text("此 Mac 没有原生 MP3 编码器，请选择 WAV 或 M4A。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("朗读预览（跳过代码块和图片；表格按表头逐项朗读）")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(model.preparedText).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 130)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            if model.isPreparing {
                ProgressView("正在整理朗读文本…").controlSize(.small)
            } else if model.isBusy {
                ProgressView(value: model.progress)
                HStack {
                    Text(model.isPreviewing ? "正在生成试听…" : "正在合成或导出语音…")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { model.cancel() }
                }
            }
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if model.exported {
                Label("语音已导出", systemImage: "checkmark.circle").foregroundStyle(.green)
            }

            HStack {
                Button("试听前段") { model.generate(preview: true) }.disabled(!model.canGenerate)
                Button("停止播放") { model.stopPlayback() }.disabled(model.player == nil)
                Spacer()
                if model.artifact != nil && !model.artifactIsPreview {
                    Button("播放") { model.replay() }.disabled(model.isBusy)
                    Button("导出音频…") { model.exportAudio() }.disabled(model.isBusy)
                }
                Button("生成完整语音") { model.generate(preview: false) }
                    .buttonStyle(.borderedProminent).disabled(!model.canGenerate)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580)
        .task(id: model.useSummary) { await model.prepare() }
        .onDisappear { model.close() }
    }
}
