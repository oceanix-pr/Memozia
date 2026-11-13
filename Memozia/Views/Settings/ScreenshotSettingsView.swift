import SwiftUI
import SwiftData
import os
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Carbon)
import Carbon.HIToolbox
#endif

// MARK: - 捕获设置视图（截图 + 录屏统一入口的偏好）
///
/// 全局热键已抽到独立的「设置 → 热键」页（`HotkeySettingsView`）；
/// 本页只保留捕获行为本身：屏幕录制权限、默认捕获模式、录屏偏好与使用说明
struct ScreenshotSettingsView: View {
    #if os(macOS)

    @AppStorage("screenshotDefaultMode") private var screenshotDefaultMode: String = "region"
    /// 录屏偏好：与 ScreenRecordingQuality.saved()/savedSource() 的缺省值一致，
    /// 与菜单栏「捕获屏幕」子菜单的快切 radio 读写同一组键
    @AppStorage(ScreenRecordingQuality.sourceDefaultsKey) private var screenSourceRaw: String = RecordingSource.mixed.rawValue
    @AppStorage(ScreenRecordingQuality.qualityDefaultsKey) private var screenQualityRaw: String = ScreenRecordingQuality.standard.rawValue
    #endif

    var body: some View {
        #if os(macOS)
        Form {
            Section("屏幕录制权限") {
                HStack(spacing: 12) {
                    Image(systemName: ScreenshotManager.hasScreenPermission ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(ScreenshotManager.hasScreenPermission ? .green : .orange)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("屏幕录制权限")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(ScreenshotManager.hasScreenPermission
                             ? "已授权，可以正常截图"
                             : "未授权，首次截图时系统会弹窗请求授权")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !ScreenshotManager.hasScreenPermission {
                        Button("打开系统设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            Section("默认捕获模式") {
                Picker("启动模式", selection: $screenshotDefaultMode) {
                    Text("区域截图").tag("region")
                    Text("窗口截图").tag("window")
                    Text("全屏截图").tag("fullscreen")
                }
                .pickerStyle(.segmented)
                Text("点击工具栏「捕获」按钮或触发热键时使用的默认模式")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("录屏偏好") {
                Picker("声源", selection: $screenSourceRaw) {
                    ForEach(RecordingSource.allCases, id: \.rawValue) { src in
                        Text(src.displayName).tag(src.rawValue)
                    }
                }
                Picker("质量", selection: $screenQualityRaw) {
                    ForEach(ScreenRecordingQuality.allCases, id: \.rawValue) { q in
                        Text("\(q.displayName)（\(q.estimatedSizeLabel)）").tag(q.rawValue)
                    }
                }
                Text("用于全部录屏入口（会话工具栏「录制」与菜单栏「捕获屏幕」直达项）；独立于会议录音设置，不影响普通录音。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("使用说明") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("工具栏「捕获」按钮、菜单栏「捕获屏幕」子菜单或全局热键均可启动；框选后可在工具栏选择保存截图或录制为视频", systemImage: "camera.viewfinder")
                    Label("录制支持全屏/选区/窗口：选定目标后点工具栏「录制」，3 秒倒计时开录，与录音共用停止链路，产物为视频+音频同文件夹入库", systemImage: "record.circle")
                    Label("框选区域后可标注：矩形 / 椭圆 / 箭头 / 画笔 / 文字 / 马赛克，支持撤销", systemImage: "pencil.and.outline")
                    Label("悬浮层工具条可复制到剪贴板、保存归档或取消", systemImage: "doc.on.clipboard")
                    Label("归档截图自动本地 OCR 识别文字，可送多模态 LLM 生成总结与待办", systemImage: "text.viewfinder")
                    Label("截图保存为 PNG 原图（不加密），存储在文稿/Memozia 文件夹按月份归档", systemImage: "photo.badge.arrow.down")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("捕获")
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        ContentUnavailableView("截图", systemImage: "camera.viewfinder", description: Text("截图功能仅支持 macOS。"))
        */
        #endif
    }

}
