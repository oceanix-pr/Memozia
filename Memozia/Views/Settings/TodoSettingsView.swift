import SwiftUI
import SwiftData
import os
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Carbon)
import Carbon.HIToolbox
#endif

// MARK: - 待办设置视图
struct TodoSettingsView: View {
    @Bindable var settingsVM: SettingsViewModel
    @ObservedObject private var remindersService = RemindersService.shared

    var body: some View {
        Form {
            Section {
                // 授权状态
                HStack(spacing: 12) {
                    Image(systemName: authStatusIcon)
                        .foregroundStyle(authStatusColor)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("提醒事项访问权限")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(authStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !remindersService.isAuthorized {
                        Button("请求权限") {
                            Task {
                                await remindersService.requestAccess()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                // 已授权：选择默认列表
                if remindersService.isAuthorized {
                    Divider()

                    HStack {
                        Label("默认提醒列表", systemImage: "list.bullet.rectangle")
                            .font(.subheadline)
                        Spacer()
                        listPicker
                    }

                    if remindersService.availableLists.isEmpty && !remindersService.isLoadingLists {
                        Text("未找到提醒事项列表，请在「提醒事项」App 中创建一个列表后点击刷新")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Button {
                        Task { await remindersService.refreshAvailableLists() }
                    } label: {
                        Label("刷新列表", systemImage: "arrow.clockwise")
                    }
                    .disabled(remindersService.isLoadingLists)
                }
            } header: {
                Text("提醒事项")
            } footer: {
                Text("AI 拆解出的待办事项将写入此处选择的提醒事项列表。授权被拒时，待办仅在 App 内展示，无法写入系统提醒事项。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("总结 → 待办", systemImage: "sparkles")
                    Label("快捷笔记（文字/图片）→ 待办", systemImage: "note.text")
                    Label("待办支持优先级、截止时间、备注", systemImage: "tag")
                    Label("写入提醒事项后保留本地记录，可重新导出", systemImage: "tray.full")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("功能说明")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("待办")
        .task {
            remindersService.refreshAuthorizationStatus()
            if remindersService.isAuthorized {
                await remindersService.refreshAvailableLists()
            }
        }
    }

    // MARK: - 子视图

    @ViewBuilder
    private var listPicker: some View {
        if remindersService.isLoadingLists {
            ProgressView().controlSize(.small)
        } else if remindersService.availableLists.isEmpty {
            Text("无可用列表")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("默认提醒列表", selection: Binding(
                get: { settingsVM.defaultReminderListID },
                set: { newValue in
                    settingsVM.defaultReminderListID = newValue
                    settingsVM.saveSettings()
                }
            )) {
                Text("使用系统默认").tag("")
                ForEach(remindersService.availableLists, id: \.calendarIdentifier) { calendar in
                    Text(calendar.title).tag(calendar.calendarIdentifier)
                }
            }
            .labelsHidden()
        }
    }

    private var authStatusIcon: String {
        switch remindersService.authorizationStatus {
        case .fullAccess, .authorized: return "checkmark.shield.fill"
        case .denied:                  return "xmark.shield.fill"
        default:                       return "shield.lefthalf.filled"
        }
    }

    private var authStatusColor: Color {
        switch remindersService.authorizationStatus {
        case .fullAccess, .authorized: return .green
        case .denied:                  return .red
        default:                       return .orange
        }
    }

    private var authStatusText: String {
        switch remindersService.authorizationStatus {
        case .fullAccess, .authorized: return String(localized: "已授权")
        case .denied:                  return String(localized: "已拒绝。请到系统设置 → 隐私与安全性 → 提醒事项 中开启 Memozia")
        case .restricted:              return String(localized: "受限（ parental controls 等限制）")
        case .notDetermined:           return String(localized: "未授权，点击右侧按钮请求")
        case .writeOnly:               return String(localized: "部分授权")
        @unknown default:              return String(localized: "未知状态")
        }
    }
}
