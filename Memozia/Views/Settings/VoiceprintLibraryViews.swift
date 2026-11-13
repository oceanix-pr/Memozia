import SwiftUI
import SwiftData
import os
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Carbon)
import Carbon.HIToolbox
#endif

// MARK: - 声纹库管理视图

/// 声纹库管理：查看/重命名/删除/合并同名已注册声纹
struct VoiceprintLibraryView: View {
    private let library = VoiceprintLibrary.shared
    /// 分页大小：每页 10 条，避免声纹较多时一次性渲染长列表
    private let pageSize = 10

    @State private var currentPage = 0
    @State private var renamingVoiceprint: Voiceprint?
    @State private var voiceprintToDelete: Voiceprint?
    @State private var showDeleteConfirmation = false
    /// 同名合并：确认弹窗 + 结果提示（nil 不展示）
    @State private var showMergeConfirmation = false
    @State private var mergeResultMessage: String?

    private var totalCount: Int { library.voiceprints.count }
    private var totalPages: Int { max(1, (totalCount + pageSize - 1) / pageSize) }
    /// 删除等操作导致总数变化后 currentPage 可能越界，展示与翻页均基于收敛后的页码
    private var effectivePage: Int { min(currentPage, totalPages - 1) }
    private var pagedVoiceprints: [Voiceprint] {
        Array(library.voiceprints.dropFirst(effectivePage * pageSize).prefix(pageSize))
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("声纹库文件夹")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(VoiceprintFolder.defaultPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    // 同名多条目（同人声音差异大时注册不达 0.65 查重阈值产生）才展示合并入口
                    if library.mergeableGroupNameCount > 0 {
                        Button {
                            showMergeConfirmation = true
                        } label: {
                            Label("合并同名", systemImage: "arrow.triangle.merge")
                        }
                        .buttonStyle(.borderless)
                        .help("库内存在同名多条目：加权合并为一条")
                    }
                    #if os(macOS)
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: VoiceprintFolder.defaultPath))
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("在 Finder 中打开声纹库文件夹")
                    .accessibilityLabel(Text("在 Finder 中打开声纹库文件夹"))
                    #endif
                }

                ForEach(pagedVoiceprints) { voiceprint in
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(.tint)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voiceprint.name)
                                .font(.subheadline)
                            Text("更新于 \(voiceprint.updatedAt, format: .dateTime.year().month().day().hour().minute()) · \(voiceprint.sampleCount) 个片段")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            renamingVoiceprint = voiceprint
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("重命名")
                        // .help 只提供鼠标 tooltip；补语义标签供 VoiceOver 使用
                        .accessibilityLabel(Text("重命名"))
                        Button {
                            voiceprintToDelete = voiceprint
                            showDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help("删除声纹")
                        .accessibilityLabel(Text("删除声纹"))
                    }
                }

                if library.voiceprints.isEmpty {
                    Text("尚未注册声纹。转写完成后在转写页点底部“声纹”按钮，为说话人填写真实姓名即可注册。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if totalPages > 1 {
                    // 分页控制：上一页 / 页码指示 / 下一页
                    HStack {
                        Button {
                            currentPage = max(0, effectivePage - 1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                        .disabled(effectivePage == 0)
                        .help("上一页")
                        .accessibilityLabel(Text("上一页"))

                        Spacer()

                        Text("第 \(effectivePage + 1) / \(totalPages) 页 · 共 \(totalCount) 条")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        Spacer()

                        Button {
                            currentPage = min(totalPages - 1, effectivePage + 1)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.borderless)
                        .disabled(effectivePage >= totalPages - 1)
                        .help("下一页")
                        .accessibilityLabel(Text("下一页"))
                    }
                }
            } header: {
                Text("已注册声纹（\(library.voiceprints.count)）")
            }

            Section {
                Text("转写时说话人分离完成后自动与声纹库比对，命中的说话人直接标注为注册姓名，未命中保留“说话人 N”。声纹以 JSON 格式存储（含嵌入向量），仅本机可读。更换嵌入模型后旧声纹会自动停用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("说明")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("声纹库")
        .onAppear {
            library.reload()
        }
        .sheet(item: $renamingVoiceprint) { voiceprint in
            VoiceprintRenameSheet(voiceprint: voiceprint)
        }
        .alert("删除声纹", isPresented: $showDeleteConfirmation) {
            Button("删除", role: .destructive) {
                if let voiceprint = voiceprintToDelete {
                    library.delete(voiceprint)
                }
                voiceprintToDelete = nil
            }
            Button("取消", role: .cancel) {
                voiceprintToDelete = nil
            }
        } message: {
            Text("确定删除「\(voiceprintToDelete?.name ?? "")」的声纹吗？删除后转写将不再自动识别该人员。")
        }
        .alert("合并同名声纹", isPresented: $showMergeConfirmation) {
            Button("合并") {
                do {
                    let groups = try library.mergeSameNames()
                    mergeResultMessage = groups > 0
                        ? String(format: String(localized: "已合并 %lld 组同名声纹"), groups)
                        : String(localized: "没有可合并的同名声纹")
                } catch {
                    mergeResultMessage = String(format: String(localized: "合并失败：%@"), error.localizedDescription)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将同名且同模型的多条声纹按样本数加权合并为一条（向量取质心，来源录音合并）；无跨模型合并，原条目归入最早一条。")
        }
        .alert("合并结果", isPresented: Binding(
            get: { mergeResultMessage != nil },
            set: { if !$0 { mergeResultMessage = nil } }
        )) {
            Button("好", role: .cancel) { mergeResultMessage = nil }
        } message: {
            Text(mergeResultMessage ?? "")
        }
    }
}


/// 声纹重命名弹窗
struct VoiceprintRenameSheet: View {
    let voiceprint: Voiceprint
    private let library = VoiceprintLibrary.shared

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(voiceprint: Voiceprint) {
        self.voiceprint = voiceprint
        _draft = State(initialValue: voiceprint.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("重命名声纹")
                .font(.headline)
            TextField("姓名", text: $draft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    library.rename(voiceprint, to: draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
