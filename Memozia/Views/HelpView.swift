import SwiftUI

/// Memozia 使用帮助视图（简洁版）
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(String(localized: "Memozia 帮助"))
                    .font(.title3)
                Spacer()
                Button(String(localized: "关闭")) {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    helpSection(
                        title: String(localized: "会议录音"),
                        icon: "record.circle",
                        items: [
                            String(localized: "点击工具栏「开始会议录音」按钮开始录音，支持麦克风和系统音频同时录制"),
                            String(localized: "录音过程中可在顶部工具栏查看时长和静音状态"),
                            String(localized: "当前不自动跟随会议软件静音，请在 Memozia 中手动静音或解除静音。"),
                            String(localized: "也可在录音界面手动静音/解除静音"),
                            String(localized: "可在「设置 → 录音 → 输入设备」开启「录音开始时静音麦克风」，之后每次开始录音或录屏都先静音麦克风，录音中可随时解除；菜单栏与录制工具栏的麦克风菜单读写同一份偏好"),
                            String(localized: "录音结束后，文件自动保存到数据文件夹中"),
                        ]
                    )

                    helpSection(
                        title: String(localized: "麦克风选择"),
                        icon: "mic",
                        items: [
                            String(localized: "可在「设置 → 录音 → 输入设备」指定使用哪个麦克风（含外接麦与 Loopback 等虚拟设备）；未指定时跟随系统默认输入设备"),
                            String(localized: "菜单栏「麦克风」子菜单内可快速切换麦克风；截图会话工具栏「录制」旁也有麦克风按钮，倒计时会显示当前质量、声源与麦克风供最后确认"),
                            String(localized: "麦克风选择只保存在本机并只作用于 Memozia，不会改变系统默认输入设备；所选设备被拔出时自动回退系统默认"),
                        ]
                    )

                    helpSection(
                        title: String(localized: "导入音频与视频"),
                        icon: "microphone.badge.plus",
                        items: [
                            String(localized: "点击侧边栏工具栏的「导入」按钮选择媒体文件，也可直接把文件拖到侧边栏"),
                            String(localized: "支持 m4a、mp3、wav，也支持 mp4、mov、m4v 视频导入（自动抽取音轨，原始视频同文件夹保留）"),
                        ]
                    )

                    helpSection(
                        title: String(localized: "视频理解"),
                        icon: "rectangle.stack.badge.play",
                        items: [
                            String(localized: "打开视频条目后切换到「画面」Tab，可一边播放原视频，一边查看视觉纪要和关键帧时间轴"),
                            String(localized: "选择视觉模型后点击「分析画面」；不支持图片的模型会先在本机 OCR，只把带时间标记的文字发给模型"),
                            String(localized: "点击关键帧可让播放器跳到对应时间；更换模型重新分析时会复用已抽取的关键帧"),
                            String(localized: "空间紧张时可点「清理视频」：只删原始视频文件，关键帧与画面要点保留，仍可继续或重新分析"),
                        ]
                    )

                    helpSection(
                        title: String(localized: "快捷笔记"),
                        icon: "text.pad.header.badge.plus",
                        items: [
                            String(localized: "无需录音也可快速记录：粘贴文字或拖入图片即可创建笔记"),
                            String(localized: "快捷笔记可直接由 AI 拆解为待办事项，也可生成 AI 总结"),
                            String(localized: "图片笔记支持本地 Vision OCR 识别或直接发送给支持视觉的 LLM"),
                            String(localized: "图片查看支持缩放、拖拽和全屏查看，方便对比细节"),
                            String(localized: "拆解待办或生成总结后自动生成简短标题并更新列表标题"),
                        ]
                    )

                    helpSection(
                        title: String(localized: "转为语音"),
                        icon: "speaker.wave.2",
                        items: [
                            String(localized: "使用 macOS 系统音色在本机合成，文字不会发送到云端。"),
                            String(localized: "文字笔记可点「转为语音」，选择朗读笔记正文或已有总结；入口仅在中文界面显示"),
                            String(localized: "可选择语言与地区、系统音色和语速，先「试听前段」，满意后再「生成完整语音」，并可导出为 WAV 或 M4A 音频（此 Mac 无原生 MP3 编码器时不可选 MP3）"),
                            String(localized: "关闭面板即取消合成并清理临时音频，不会生成录音条目"),
                        ]
                    )

                    helpSection(
                        title: String(localized: "转写"),
                        icon: "square.text.square",
                        items: [
                            String(localized: "选中录音后，点击工具栏「转写」按钮开始语音识别"),
                            String(localized: "转写支持 Markdown 渲染和直接编辑"),
                            String(localized: "macOS 26 及以上默认使用系统语音识别；专业模式可选择 WhisperKit 或云端转写。"),
                            String(localized: "支持简体中文、繁体中文和多语言转写"),
                            String(localized: "支持说话人分离，自动标注“说话人 N”，并可与声纹库比对标注真实姓名"),
                            String(localized: "长会议（超过约 30 分钟）的说话人区分分段处理，进度会显示当前段号"),
                            String(localized: "专业模式下可在「设置 → 转写」调整说话人区分的「精细度」五档：越高边界越准、越吃 CPU 与内存，中间档为默认"),
                            String(localized: "编辑模式下按 ⌘F 查找、⌘R 全部替换，实时显示匹配数量"),
                            String(localized: "可在「设置 → 词典」添加术语，自动纠正同音误写"),
                        ]
                    )

                    helpSection(
                        title: String(localized: "声纹识别"),
                        icon: "person.wave.2",
                        items: [
                            String(localized: "在转写页点「声纹」按钮，为说话人标记真实姓名并注册声纹"),
                            String(localized: "标记前可点每行左侧的播放按钮，试听该说话人最早的一段，便于判断是谁"),
                            String(localized: "后续录音自动识别已注册说话人并标注姓名"),
                            String(localized: "同一人的多条声纹（不同场次分别注册）在识别时会自动合并；也可在「设置 → 声纹库」用「合并同名」整理"),
                            String(localized: "识别偏保守：相似度不足或与他人嗓音接近时保留「说话人 N」，宁可不标注也不错标"),
                            String(localized: "声纹库可在「设置 → 声纹库」中查看、重命名和删除"),
                        ]
                    )

                    helpSection(
                        title: String(localized: "总结"),
                        icon: "brain",
                        items: [
                            String(localized: "转写完成后，切换到「总结」Tab，点击「生成总结」"),
                            String(localized: "支持 LM Studio、Ollama、云端 API 等多种 LLM"),
                            String(localized: "AI 会智能判断是否为会议：是会议输出完整会议纪要，否则输出概要总结"),
                            String(localized: "总结内容支持编辑和导出为 Markdown 或 PDF"),
                            String(localized: "生成总结完成后自动生成简短标题并更新列表标题"),
                            String(localized: "「设置 → 大模型 → 配置迁移」可导出/导入模型配置（含 API Key），导出文件自动加密、无需设密码，但只能在本机 Memozia 导入"),
                        ]
                    )

                    helpSection(
                        title: String(localized: "AI 待办拆解"),
                        icon: "checklist",
                        items: [
                            String(localized: "从转写或快捷笔记中由 AI 自动拆解出待办事项"),
                            String(localized: "待办支持手动新增、编辑、删除，不锁定于 AI 结果"),
                            String(localized: "点击「写入提醒事项」可一键同步到系统「提醒事项」App"),
                            String(localized: "已导出的待办修改/删除时会自动同步到提醒事项"),
                        ]
                    )

                    helpSection(
                        title: String(localized: "处理队列与一键处理"),
                        icon: "wand.and.stars",
                        items: [
                            String(localized: "在列表右键「一键处理」，或在录音/录屏播放条右侧、笔记的「拆解待办」旁点击「一键处理」：先弹出预览列出将执行/将跳过的步骤，确认后才开始"),
                            String(localized: "预览里已完成的步骤默认跳过；只有显式勾选「重新转写」才会覆盖已有转写，存在手动编辑的转写会先自动备份，云端图片/视频帧会在预览中说明数据范围"),
                            String(localized: "录音与录屏默认按会议总结，文字与图片按概要总结；一键处理的画面分析不弹确认，直接交由多模态大模型处理"),
                            String(localized: "所有处理任务（转写、总结、润色标题、画面分析、拆解待办、下载模型）都在右上角「处理队列」中调度，最多 3 个并行，其余排队"),
                            String(localized: "在队列面板中：处理中的任务可取消，模型下载还可暂停/继续（保留已下载分片续传）；排队中的任务可取消"),
                            String(localized: "失败的步骤会保留在队列「最近失败」区：显示失败原因、时间与是否可重试，可直接重试该步骤、重新执行整个任务，或打开设置与定位条目文件夹"),
                            String(localized: "一键处理只把待办保存到条目，不会自动写入系统提醒事项，需在待办页确认后手动写入"),
                        ]
                    )

                    helpSection(
                        title: String(localized: "智能截图"),
                        icon: "camera.viewfinder",
                        items: [
                            String(localized: "从菜单栏「捕获屏幕」或全局快捷键启动截图；专业模式另提供窗口、全屏与录屏。"),
                            String(localized: "截图现场自由选择模式：拖拽框选区域、悬停点击截取窗口、按空格截取全屏；多显示器环境自动覆盖所有屏幕"),
                            String(localized: "支持延时截图：菜单栏选择 3 秒或 5 秒倒计时，方便截取菜单、弹窗等瞬态界面"),
                            String(localized: "框选后可标注：矩形、椭圆、箭头、画笔、文字、马赛克，支持撤销（⌘Z）/重做（⇧⌘Z）"),
                            String(localized: "标注工具栏快捷键：R 矩形 / O 椭圆 / A 箭头 / P 画笔 / M 马赛克 / T 文字 / V 选择"),
                            String(localized: "文字标注可设置字号、粗体、斜体和颜色；双击已有文字标注可二次编辑"),
                            String(localized: "使用选择工具可点击选中单个标注，支持移动、删除（Delete 键）和修改属性"),
                            String(localized: "悬浮层工具条可复制到剪贴板或保存归档（微信截图风格）；「保存为文件…」会弹出保存窗让你选择保存位置与文件名，默认落在上次保存的目录（首次为桌面），取消保存窗不影响已绘标注"),
                            String(localized: "工具栏「钉住」按钮可将截图置顶常驻屏幕并继续标注，点击保存后入库归档；「OCR识别」按钮则先钉住截图，并在钉住窗口右侧弹出识别文字面板，可直接编辑或复制（单纯钉住时没有这块文字）"),
                            String(localized: "截图保存为图片笔记，与录音笔记统一按月份归档；右键「重新标注」可在可调大小的窗口中继续编辑标注"),
                            String(localized: "截图自动本地 OCR 识别文字，可送多模态 LLM 生成总结并拆解待办"),
                            String(localized: "视觉模型可直接发送图片；非视觉模型自动降级为 OCR 文字总结，确保兼容性"),
                            String(localized: "截图待办支持写入系统「提醒事项」，修改/删除自动同步"),
                        ]
                    )

                    helpSection(
                        title: String(localized: "菜单栏与后台录音"),
                        icon: "menubar.rectangle",
                        items: [
                            String(localized: "菜单栏使用「截图框 + 麦克风文稿」图标，自动适配深浅色。"),
                            String(localized: "会议中共享屏幕前，点菜单栏图标「隐藏主窗口」，界面与 Dock 图标一并隐藏，录音在后台继续运行"),
                            String(localized: "无需打开主窗口，可直接从菜单栏开始/停止录音，或发起区域/窗口/全屏截图"),
                            String(localized: "菜单栏实时显示录音/录屏状态（录音中/录屏中/静音），录屏时停止项显示「停止录制」"),
                            String(localized: "点窗口红色关闭按钮只隐藏窗口不退出，可随时从菜单栏或 Dock 图标恢复"),
                            String(localized: "菜单栏「从剪贴板新建笔记」可把剪贴板文字快速存为快捷笔记"),
                        ]
                    )

                    helpSection(
                        title: String(localized: "录音管理"),
                        icon: "folder",
                        items: [
                            String(localized: "右键录音或笔记可重命名、隐藏、在 Finder 中显示或删除"),
                            String(localized: "按住 ⌘ 或 ⇧ 点击可多选；右键可批量隐藏或删除"),
                            String(localized: "右键「导出」可导出原始录音，或将转写、总结导出为 Markdown 或 PDF，也可一键复制内容"),
                            String(localized: "图片/文字笔记的右键「导出」可导出总结为 Markdown 或 PDF，或一键复制"),
                            String(localized: "右键「润色标题」可由 AI 从总结与待办提取主旨更新标题"),
                            String(localized: "隐藏的录音与笔记可在「设置 → 数据管理 → 显示隐藏的条目」中查看"),
                            String(localized: "录音文件存储在「设置 → 数据文件夹」指定的路径下，按月份自动分组"),
                            String(localized: "转写、总结、待办文件均会备份到对应录音文件夹中"),
                            String(localized: "录音详情会显示采集完整性报告（音轨中断、恢复与静音证据）；设备异常、保存失败与自动恢复提醒通过横幅提示，可点「查看详情」定位条目"),
                        ]
                    )

                    helpSection(
                        title: String(localized: "数据与隐私"),
                        icon: "lock.shield",
                        items: [
                            String(localized: "转写文本和总结默认加密存储"),
                            String(localized: "首次启动会执行加密迁移，旧数据自动升级"),
                            String(localized: "原始音频、视频、图片与导出文件不额外加密，请妥善保护数据文件夹。"),
                            String(localized: "云端文本请求会先在本机去标识化；音频、截图和视频帧不做文本脱敏。"),
                        ]
                    )

                    if AppUpdateService.shared.isStarted {
                        helpSection(
                            title: String(localized: "检查更新…"),
                            icon: "arrow.down.circle",
                            items: [
                                String(localized: "可在「设置 → 关于」检查更新；安装须确认，录音或处理任务进行中会延后。"),
                            ]
                        )
                    }

                    shortcutReferenceSection()
                }
                .padding()
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
        }
        #if os(macOS)
        .frame(width: 720, height: 760)
        #endif
    }

    // MARK: - 快捷键小节（名称与当前快捷键来自 AppCommandCatalog）

    /// 快捷键列表不再硬编码：名称与快捷键取自 `AppCommandCatalog`（菜单栏 / 应用菜单 /
    /// 设置搜索共用同一份描述），全局热键的显示值实时读取 `GlobalHotkeyManager`，
    /// 因此用户在设置里改完热键，这里立刻显示新组合键，不会留下写死的旧值。
    @ViewBuilder
    private func shortcutReferenceSection() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .foregroundStyle(.tint)
                    .font(.headline)
                Text("快捷键")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(AppCommandCatalog.shortcutReferenceIDs, id: \.self) { id in
                    let descriptor = AppCommandCatalog.descriptor(for: id)
                    if let display = descriptor.shortcut.display {
                        HStack(alignment: .top, spacing: 6) {
                            Text("·")
                                .foregroundStyle(.secondary)
                            Text(display)
                                .font(.body.monospaced())
                                .frame(minWidth: 66, alignment: .leading)
                            Text(descriptor.localizedTitle)
                                .font(.body)
                                .foregroundStyle(.secondary)
                            // 仅对「可在设置中改」的全局热键标注设置去向
                            if descriptor.shortcut.isGlobalHotkey,
                               let destination = descriptor.settingsDestination {
                                Text("（可在设置 → \(destination.localizedName) 中修改）")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                // 截图标注与编辑框内的组合键不经过应用菜单，仍在此说明
                ForEach(Self.extraShortcutNotes, id: \.self) { note in
                    HStack(alignment: .top, spacing: 6) {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(note)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 22)
        }
    }

    /// 不属于应用命令目录的快捷键说明（标注工具与编辑框内的组合键）
    private static let extraShortcutNotes: [String] = [
        String(localized: "截图标注时：R 矩形 / O 椭圆 / A 箭头 / P 画笔 / M 马赛克 / T 文字 / V 选择"),
        String(localized: "截图标注时：⌘Z 撤销 / ⇧⌘Z 重做 / Delete 删除选中标注 / ESC 取消"),
        String(localized: "编辑模式：⌘F 查找 / ⌘R 全部替换（转写与总结的编辑框内生效）"),
    ]

    // MARK: - 帮助分区

    @ViewBuilder
    private func helpSection(title: String, icon: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                    .font(.headline)
                Text(title)
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(item)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 22)
        }
    }
}
