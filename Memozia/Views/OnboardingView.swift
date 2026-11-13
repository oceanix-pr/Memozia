import SwiftUI

/// 首次启动新手引导
struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// 完成引导时的应用版本：升级到新版本后 RootView 会重新展示引导介绍新功能
    @AppStorage("onboardingCompletedVersion") private var onboardingCompletedVersion = ""
    @Environment(\.dismiss) private var dismiss

    @State private var currentPage = 0

    private let professionalPages: [OnboardingPage] = [
        OnboardingPage(
            icon: "waveform.circle.fill",
            title: String(localized: "欢迎使用 Memozia"),
            subtitle: String(localized: "会议录音转写与智能总结工具"),
            description: String(localized: "默认在本机录音和转写。总结与待办由你配置的智能服务生成；使用云端服务会发送相应内容。")
        ),
        OnboardingPage(
            icon: "record.circle.fill",
            title: String(localized: "会议录音"),
            subtitle: String(localized: "麦克风 + 系统音频"),
            description: String(localized: "支持录制本机麦克风和系统输出音频（仅 macOS）。录音文件统一存储在文稿目录下的 Memozia 文件夹，按月份分组，以年月日时分秒命名。")
        ),
        OnboardingPage(
            icon: "video.fill",
            title: String(localized: "屏幕录制"),
            subtitle: String(localized: "全屏 / 区域 / 窗口 + 可选麦克风"),
            description: String(localized: "菜单栏「捕获屏幕」可选择全屏、区域或窗口录屏，画面与音频同步入库为视频条目，可播放、抽关键帧并生成视觉纪要。麦克风可在设置、菜单栏或截图工具栏中选择（含外接麦与虚拟设备）；声源选「仅系统音频」时只录系统声音。")
        ),
        OnboardingPage(
            icon: "menubar.rectangle",
            title: String(localized: "菜单栏控制"),
            subtitle: String(localized: "共享屏幕时不被看到"),
            description: String(localized: "菜单栏使用「截图框 + 麦克风文稿」图标，可控制录音、捕获屏幕和显示主窗口。共享屏幕时可隐藏主窗口与 Dock 图标。")
        ),
        OnboardingPage(
            icon: "arrow.down.circle.fill",
            title: String(localized: "导入音频与视频"),
            subtitle: String(localized: "支持多种音频与视频格式"),
            description: String(localized: "拖拽音频文件到窗口，或点击工具栏的导入按钮。支持 m4a、mp3、wav，也支持 mp4、mov、m4v 视频（自动抽取音轨，原始视频同文件夹保留）。导入文件同样存储到 Memozia 文件夹。")
        ),
        OnboardingPage(
            icon: "rectangle.stack.badge.play.fill",
            title: String(localized: "视频理解"),
            subtitle: String(localized: "播放、关键帧与视觉纪要"),
            description: String(localized: "打开导入的视频并切换到「画面」Tab，可播放原视频、手动分析画面并查看关键帧时间轴。视觉模型读取关键帧；普通文本模型会先在本机 OCR。点击任一关键帧即可跳到对应时间。")
        ),
        OnboardingPage(
            icon: "text.bubble.fill",
            title: String(localized: "语音转写"),
            subtitle: String(localized: "本地或云端转写"),
            description: String(localized: "macOS 26 及以上默认使用系统语音识别；专业模式可选择 WhisperKit 或云端转写。")
        ),
        OnboardingPage(
            icon: "person.wave.2",
            title: String(localized: "声纹识别"),
            subtitle: String(localized: "自动认出老朋友"),
            description: String(localized: "需单独同意后才能注册和比对声纹。声纹仅保存在本机，可在「设置 → 声纹库」删除。")
        ),
        OnboardingPage(
            icon: "text.pad.header.badge.plus",
            title: String(localized: "快捷笔记"),
            subtitle: String(localized: "随手记录与待办拆解"),
            description: String(localized: "粘贴文字或拖入图片即可创建笔记，AI 可将笔记拆解为待办事项并写入系统提醒事项，也可生成 AI 总结。图片查看支持缩放、拖拽和全屏查看。文字笔记还可用系统音色在本机转为语音，并导出为 WAV 或 M4A 音频。")
        ),
        OnboardingPage(
            icon: "camera.viewfinder",
            title: String(localized: "智能截图"),
            subtitle: String(localized: "区域/窗口/全屏 + 丰富标注 + AI 总结"),
            description: String(localized: "随时按 ⌃⌘S 启动截图（全局热键，可自定义）。支持区域框选、窗口拾取、全屏截取三种模式，多显示器自动覆盖。提供矩形、椭圆、箭头、画笔、文字、马赛克等标注工具，支持 3 秒/5 秒延时截图、撤销重做、单个标注选择删除、文字二次编辑。可一键钉住截图置顶屏幕继续标注，右键「重新标注」可在可调大小的窗口中再次编辑。截图作为图片笔记归档，自动 OCR 识别并可送 AI 生成总结和待办。")
        ),
        OnboardingPage(
            icon: "brain.head.profile.fill",
            title: String(localized: "智能总结"),
            subtitle: String(localized: "AI 生成会议纪要"),
            description: String(localized: "配置 LLM（LM Studio / Ollama / OpenAI）自动生成总结、关键议题和待办事项。AI 智能判断是否为会议：是会议输出完整会议纪要，否则输出概要总结。生成完成后自动为录音生成简短标题。编辑转写或总结时按 ⌘F 查找、⌘R 全部替换。")
        ),
        OnboardingPage(
            icon: "wand.and.stars",
            title: String(localized: "一键处理与处理队列"),
            subtitle: String(localized: "转写、画面、总结、待办一次跑完"),
            description: String(localized: "在录音、录屏或笔记上点「一键处理」，自动按「转写 → 画面分析（录屏）→ 总结 → 拆解待办」依次完成（已完成的步骤默认跳过；如需覆盖已有转写，可在预览中显式开启「重新转写」）；录音与录屏默认会议总结，文字与图片按概要总结。所有处理任务（含模型下载）都在右上角「处理队列」中排队，最多 3 个并行；下载模型可暂停/继续，其余任务可取消。")
        )
    ]

    /// 首次安装默认普通模式：引导只介绍能立即使用的主链路，
    /// 避免新用户还没进入主界面就被声源、模型、声纹和视频理解术语淹没。
    private var standardPages: [OnboardingPage] {
        [
            OnboardingPage(
                icon: "waveform.circle.fill",
                title: String(localized: "欢迎使用 Memozia"),
                subtitle: String(localized: "从录音到待办，一步完成"),
                description: String(localized: "默认在本机录音和转写。总结与待办由你配置的智能服务生成；使用云端服务会发送相应内容。")
            ),
            OnboardingPage(
                icon: "record.circle.fill",
                title: String(localized: "选择会议类型"),
                subtitle: String(localized: "线上会议或面对面会议"),
                description: String(localized: "只需告诉 Memozia 会议在线上还是同一空间进行，应用会自动选择合适的录音方式。")
            ),
            OnboardingPage(
                icon: "tray.and.arrow.down.fill",
                title: String(localized: "导入或开始录音"),
                subtitle: String(localized: "音频和视频都可以"),
                description: String(localized: "点击工具栏的录音按钮，或把 m4a、mp3、wav、mp4、mov 文件拖进窗口。")
            ),
            OnboardingPage(
                icon: "text.bubble.fill",
                title: String(localized: "快捷笔记"),
                subtitle: String(localized: "随手记录，自动拆解待办"),
                description: String(localized: "新建文字或图片笔记，即可生成总结、拆解待办，并在你确认后写入系统提醒事项。")
            ),
            OnboardingPage(
                icon: "camera.viewfinder",
                title: String(localized: "区域截图"),
                subtitle: String(localized: "截图、标注并归档"),
                description: String(localized: "从菜单栏「捕获屏幕」或全局快捷键启动截图；专业模式另提供窗口、全屏与录屏。")
            ),
            OnboardingPage(
                icon: "brain.head.profile.fill",
                title: String(localized: "连接智能服务"),
                subtitle: String(localized: "自动生成总结和待办"),
                description: String(localized: "在“设置 → 智能服务”填入 API Key 即可使用。普通模式会自动选择总结方式并在云端请求前保护文本中的个人信息。")
            ),
            OnboardingPage(
                icon: "wand.and.stars",
                title: String(localized: "一键处理"),
                subtitle: String(localized: "转写、总结、待办一次跑完"),
                description: String(localized: "在录音或笔记上点「一键处理」：默认依次完成尚未处理的步骤（已完成的会跳过；需要时可在预览中显式开启「重新转写」），再生成总结并拆解待办。任务会在右上角「处理队列」里排队执行，可随时查看进度或取消。")
            )
        ]
    }

    private var pages: [OnboardingPage] {
        AppExperiencePreference.resolved() == .pro ? professionalPages : standardPages
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentPage) {
                ForEach(pages.indices, id: \.self) { index in
                    pageView(pages[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.automatic)

            // 底部控制栏
            HStack {
                // 随时可退出：旧版引导没有跳过入口且被 interactiveDismissDisabled 挡住，
                // 老用户升级后必须连点 10+ 页才能回到主界面
                Button(String(localized: "关闭")) {
                    finishOnboarding()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if currentPage > 0 {
                    Button(String(localized: "上一步")) {
                        withAnimation { currentPage -= 1 }
                    }
                }

                Spacer()

                // 页面指示器（纯装饰圆点需补无障碍语义：VoiceOver 用户应能知道当前页与总页数）
                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { index in
                        Circle()
                            .fill(index == currentPage ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    String(format: String(localized: "第 %lld 页，共 %lld 页"), currentPage + 1, pages.count)
                )

                Spacer()

                if currentPage < pages.count - 1 {
                    Button(String(localized: "下一步")) {
                        withAnimation { currentPage += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(String(localized: "开始使用")) {
                        finishOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
        #if os(macOS)
        .frame(width: 560, height: 500)
        #endif
    }

    /// 结束引导页：记录完成版本，后续仅主/次版本变化时重弹（见 RootView.onboardingNeedsRefresh）
    private func finishOnboarding() {
        hasCompletedOnboarding = true
        onboardingCompletedVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        dismiss()
    }

    private func pageView(_ page: OnboardingPage) -> some View {
        // 固定 560×500 窗口在长文案（德语/俄语）、最大辅助字号或窄窗口下会截断，
        // 因此内容整体放入 ScrollView；内容较短时用 minHeight 保持垂直居中
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    // 纯装饰图标：标题/副标题已表达信息，避免 VoiceOver 读成 SF Symbol 名
                    Image(systemName: page.icon)
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)
                        .symbolRenderingMode(.hierarchical)
                        .accessibilityHidden(true)

                    Text(page.title)
                        .font(.title)
                        .fontWeight(.bold)

                    Text(page.subtitle)
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    Text(page.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .center)
            }
        }
    }
}

private struct OnboardingPage {
    let icon: String
    let title: String
    let subtitle: String
    let description: String
}
