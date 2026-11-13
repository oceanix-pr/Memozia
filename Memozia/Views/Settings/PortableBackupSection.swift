import SwiftUI
import AppKit

struct PortableBackupSection: View {
    var isReadOnly: Bool
    @State private var password = ""
    @State private var confirmation = ""
    @State private var task: Task<Void, Never>?
    @State private var result: PortableBackup.Report?
    @State private var message = ""
    @State private var busy = false
    @State private var restored = false

    var body: some View {
        Section("跨设备加密备份") {
            SecureField("备份口令（至少 12 个字符）", text: $password)
            SecureField("再次输入口令（创建备份时）", text: $confirmation)
            Text("请妥善保存口令，遗失后无法恢复。备份包含条目文本和支持的媒体文件，不含 API Key、模型、数据库或后台队列。创建期间请勿录音或编辑。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("创建迁移备份") { start(restoring: false) }
                    .disabled(busy || isReadOnly || password.count < 12 || password != confirmation)
                Button("从迁移备份恢复…") { start(restoring: true) }
                    .disabled(busy || isReadOnly || password.count < 12)
                if busy {
                    ProgressView().controlSize(.small)
                    Button("取消") { task?.cancel() }
                }
            }
            if !message.isEmpty { Text(verbatim: message).font(.caption).textSelection(.enabled) }
            if let result {
                Text("处理文件：\(result.files)，未纳入文件：\(result.skipped)")
                    .font(.caption)
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
                if restored {
                    Text("恢复结果位于独立目录，未合并或替换当前资料。请核对文件后，在“数据文件夹”中选择恢复目录并重启应用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onDisappear { task?.cancel(); password = ""; confirmation = "" }
    }

    private func chooseDirectory(_ prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func start(restoring: Bool) {
        guard !isReadOnly, !MeetingRecorderService.shared.isRecording else {
            message = String(localized: "请先停止录音，并确认应用具有数据写入权限。")
            return
        }
        switch BackgroundTaskQueue.readResult() {
        case .loaded(let queue) where queue.tasks.isEmpty && queue.inProgressID == nil: break
        default:
            message = String(localized: "请等待处理队列完成；队列无法读取时也不能开始备份或恢复。")
            return
        }
        var archive: URL?
        if restoring {
            archive = chooseDirectory(String(localized: "选择 .memoziabackup 备份目录"))
            guard archive != nil else { return }
        }
        guard let parent = chooseDirectory(String(localized: "选择当前数据文件夹之外的目标位置")) else { return }
        let root = AudioRecording.storageDirectory
        let secret = password
        let selectedArchive = archive
        busy = true
        result = nil
        restored = restoring
        message = String(localized: "正在处理，请保持应用开启。恢复失败的临时目录不会影响当前资料。")
        task = Task { @MainActor in
            defer { busy = false; password = ""; confirmation = ""; task = nil }
            let work = Task.detached(priority: .utility) {
                if let selectedArchive {
                    return try await PortableBackup.restore(archive: selectedArchive, to: parent, password: secret, activeRoot: root)
                }
                return try await PortableBackup.export(root: root, to: parent, password: secret)
            }
            do {
                result = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                message = String(localized: "处理完成。请保留原始资料，并在另一台设备上演练恢复后再清理旧数据。")
            } catch is CancellationError {
                message = String(localized: "操作已取消，原有资料未被替换。")
            } catch {
                message = String(localized: "操作失败：") + error.localizedDescription
            }
        }
    }
}
