import SwiftUI
#if os(macOS)
import AppKit
#endif

struct MCPSettingsView: View {
    let isTransient: Bool
    @State private var access = MCPAccessStore.shared
    @State private var controller = MCPServerController.shared
    @State private var clientName = ""
    @State private var restrictDate = true
    @State private var since = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var redact = true
    @State private var port = MCPAccessStore.shared.port
    @State private var copied = false
    @State private var showError = false

    var body: some View {
        Form {
            Section {
                Toggle("启用本机 MCP（只读）", isOn: Binding(get: { access.enabled }, set: { value in
                    do {
                        if value && !access.enabled { try access.setPort(port) }
                        Task { await controller.setEnabled(value) }
                    } catch { showError = true }
                }))
                .disabled(isTransient)
                Text("允许你授权的本机 AI 客户端查询录音、笔记、总结、转写和待办。外部客户端可能将读取的内容发送到其使用的云端模型。")
                    .font(.callout).foregroundStyle(.secondary)
                if isTransient { Text("临时模式下无法启用 MCP。请重新连接持久化数据库。").foregroundStyle(.orange) }
                LabeledContent("服务状态") { Text(controller.statusText) }
                if access.enabled { Text(access.endpoint).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
                LabeledContent("端口") {
                    TextField("端口", value: $port, format: .number.grouping(.never))
                        .frame(width: 90).disabled(access.enabled)
                        .onSubmit {
                            do { try access.setPort(port) }
                            catch { port = access.port; showError = true }
                        }
                }
                if controller.state == .failed { Button("重试") { Task { await controller.refresh() } } }
            }
            Section("授权客户端") {
                TextField("客户端名称", text: $clientName)
                Toggle("限制共享起始日期", isOn: $restrictDate)
                if restrictDate { DatePicker("共享起始日期", selection: $since, in: ...Date(), displayedComponents: .date) }
                Toggle("对输出文本脱敏", isOn: $redact)
                Text("脱敏沿用本机词典与规则；隐藏条目始终不共享。关闭脱敏后，该客户端将读取授权范围内的原文。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("授权并复制连接配置") {
                    do {
                        let grant = try access.addClient(name: clientName, notBefore: restrictDate ? Calendar.current.startOfDay(for: since) : nil, redact: redact)
                        try copyConfiguration(grant)
                        clientName = ""
                    } catch { showError = true }
                }.disabled(isTransient || !access.enabled || clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if copied { Text("连接配置已复制（包含访问令牌），请妥善保管。").font(.callout).foregroundStyle(.secondary) }
            }
            Section("已授权客户端") {
                if access.grants.isEmpty { Text("尚未授权客户端").foregroundStyle(.secondary) }
                ForEach(access.grants) { grant in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(grant.name)
                            Text(grant.redact ? String(localized: "脱敏文本") : String(localized: "原文")).font(.caption).foregroundStyle(.secondary)
                            if let date = grant.notBefore {
                                HStack { Text("共享起始日期"); Text(date, style: .date) }.font(.caption).foregroundStyle(.secondary)
                            } else { Text("全部可见条目").font(.caption).foregroundStyle(.secondary) }
                            if let date = access.lastAccess[grant.id] {
                                HStack { Text("最近访问"); Text(date, style: .time) }.font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("复制连接配置") {
                            do { try copyConfiguration(grant) } catch { showError = true }
                        }.disabled(isTransient)
                        Button("撤销") {
                            do { try access.revoke(grant.id); copied = false } catch { showError = true }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert("MCP 设置失败", isPresented: $showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("请检查端口范围（1024–65535）及钥匙串访问权限后重试。")
        }
    }

    private func copyConfiguration(_ grant: MCPClientGrant) throws {
        let configuration = try access.configuration(for: grant)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(configuration, forType: .string) else { throw MCPQueryError.readFailed }
        copied = true
    }
}
