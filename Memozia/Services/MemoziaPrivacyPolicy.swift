import Foundation

/// Memozia 隐私政策的唯一事实来源：正文、版本号与同意状态。
///
/// 为什么要有这个文件：
/// - 旧实现把协议正文硬编码在 `PrivacyConsentView` 里，且只用一个布尔开关
///   `hasAcceptedPrivacyPolicy` 记录同意。结果是**改文本不生效**——已同意的老用户
///   永远不会再看到同意页，协议改了等于没改。
/// - 这里补上 `privacyPolicyVersion`，同意状态与版本绑定；主版本提升即视为需要重新同意。
///
/// 使用约定：
/// 1. 任何实质性文本改动都必须提升 `version` 的主版本号，否则不会触发重新同意。
/// 2. 新代码判断“是否需要弹同意页”请用 `needsConsent(...)`，不要再直接读
///    `hasAcceptedPrivacyPolicy`。
/// 3. 正文里的“第 N 节”这类交叉引用容易随章节调整失效，改用章节标题指代。
enum MemoziaPrivacyPolicy {

    /// 当前政策版本。语义：主版本号变动 = 实质性变更（需重新同意）。
    static let version = "7.0"

    /// 生效日期（yyyy-MM-dd）
    static let effectiveDate = "2026-11-13"

    /// 页眉展示用的版本文案
    static var versionLine: String {
        String(
            format: String(localized: "版本 %@ · 生效日期 %@"),
            version,
            effectiveDate
        )
    }

    private static var contactDescription: String {
        if let email = MemoziaContact.email { return "联系邮箱：\(email)。" }
        return "本地开发副本尚未配置联系邮箱；公开发布前需补充有效联系方式。"
    }

    private static var feedbackDisclosure: String {
        if MemoziaContact.email != nil {
            return "• 反馈信息：你在「用户反馈」中填写的内容与可选联系邮箱，会通过系统邮件应用发送给发布方。"
        }
        return "• 本地开发副本未配置反馈渠道，不会通过本应用接收反馈信息。"
    }

    // MARK: - 正文

    struct Section: Identifiable, Sendable {
        let id: String
        let title: String
        let body: String
        /// 涉及敏感个人信息（如声纹）等需要“单独同意”的内容。
        /// 渲染层应对此类章节给出独立的勾选项，而不是混在总体同意里。
        let requiresSeparateConsent: Bool

        init(_ id: String, _ title: String, _ body: String, separateConsent: Bool = false) {
            self.id = id
            self.title = title
            self.body = body
            self.requiresSeparateConsent = separateConsent
        }
    }

    /// 协议正文。顺序即渲染顺序。
    ///
    /// 事实来源约定：正文只能写代码可核对的行为。改动前先对照实现确认，
    /// 不要为了“看起来完整”写入尚未实现的功能。
    static let sections: [Section] = [
        Section(
            "scope",
            "适用范围与处理者",
            """
            本政策适用于 macOS 应用 Memozia（闻墨集，以下简称“本应用”）。

            个人信息处理者：Memozia 发布方。
            \(contactDescription)

            本政策说明本应用处理哪些数据、为何处理、保存在哪里，以及你对这些数据拥有的权利。首次使用或政策实质性更新后，我们会请你完整阅读并确认同意。
            """
        ),
        Section(
            "local-first",
            "本地优先",
            """
            闻墨集采用本地优先设计：录音与笔记首先保存在你的 Mac 上。语音转写默认使用本机系统语音识别或 WhisperKit；总结与待办是否在本机处理，取决于你配置的智能服务，不能一概视为离线处理。

            只有你主动配置并启用云端转写、云端大模型或云端视觉能力时，相应内容才会发送到你自行指定的第三方服务。云端请求由你的设备直接发往你配置的服务地址，不经过我们的服务器；我们不会收到这些请求中的录音、文本或画面。
            """
        ),
        Section(
            "external-mcp",
            String(localized: "外部 AI 访问（MCP，可选）"),
            String(localized: """
            本机 MCP 默认关闭。只有你在设置中启用并授权客户端后，该客户端才能读取授权日期范围内的录音与笔记标题、文字、OCR、转写、总结、画面要点和待办；隐藏条目不共享。当前接口只读，不允许外部客户端录音、删除条目或写入系统提醒事项。

            服务仅监听本机回环地址，访问令牌存于本机钥匙串，你可以随时关闭服务或撤销单个客户端。输出默认沿用本机词典与规则脱敏；你也可以明确授权客户端读取原文。脱敏不保证识别所有敏感信息，外部客户端可能将读取的内容发送到它使用的云端模型，请按需要限制共享日期并妥善保管连接配置中的访问令牌。
            """)
        ),
        Section(
            "collected",
            "我们处理的数据",
            """
            • 音频：你导入的录音文件、本机录制的会议音频与系统输出音频
            • 文本：由音频生成的转写文本，以及你手动编辑的内容
            • AI 产出：总结、待办与画面要点
            • 画面：录屏视频、截图与关键帧（可选功能）
            • 声纹特征：用于区分说话人的声音特征（可选功能，见「声纹」一节）
            • 偏好设置：输入设备、模型与提示词配置等应用设置
            \(feedbackDisclosure)

            上述数据仅用于提供你主动使用的录音、转写、说话人分离、总结、待办与画面理解功能。提供这些信息是使用对应功能所必需的；你可以拒绝提供或撤回同意，但相应功能将不可用，其余功能不受影响。

            我们不收集通讯录、位置、浏览记录与广告标识；应用内不含广告、用户画像或行为统计 SDK。
            """
        ),
        Section(
            "permissions",
            "系统权限与用途",
            """
            • 麦克风：录制你的语音。仅在你开始录音时启用，停止录音后释放。
            • 屏幕录制：通过 ScreenCaptureKit 采集系统输出音频、截图或录屏。可在「设置 → 录音 → 来源」中选择不录制系统音频。
            • 语音识别：调用 macOS 系统语音识别框架，在本地把录音转成文字。
            • 提醒事项：在你点击「写入提醒事项」，或在「设置 → 待办」主动请求权限后，读取可写列表并把 AI 拆解的待办写入你选择的列表。
            • 辅助功能（当前版本未启用）：设置中保留了「自动跟随会议软件静音」开关，但当前版本不会启动辅助功能检测。若将来启用，只会读取 Teams、Zoom、腾讯会议等会议软件静音按钮的界面状态，用于自动暂停或恢复麦克风采集；不截取屏幕、不读取会议内容、不上传，启用前会更新本政策。

            以上权限均可随时在「系统设置 → 隐私与安全性」中撤销。撤销后对应功能不可用，其余功能不受影响。
            """
        ),
        Section(
            "voiceprint",
            "声纹（敏感个人信息，需单独同意）",
            """
            说话人分离完成后，你可以为某个说话人填写真实姓名，把其声音特征注册为声纹；此后转写会自动把同一人的声音标注为该姓名。声纹属于生物识别信息，按《中华人民共和国个人信息保护法》属于敏感个人信息，因此需要你的单独同意。

            • 生成条件：仅在你勾选本页的「声纹处理单独同意」，并在转写页主动点击「声纹」并填写姓名时才会生成。未同意时不会生成声纹，也不会用声纹库比对说话人。
            • 存储位置：~/Documents/Memozia/Voiceprints/，每人一个 JSON 文件（含姓名与声纹嵌入向量），以明文保存，依赖 macOS 文件系统权限保护，未额外加密。
            • 是否上传：声纹文件与嵌入向量仅保存在本机，不会上传到我们的服务器，也不会随云端转写或云端大模型请求发送。注册的姓名会加入本机 PII 词典，用于在文本发往云端前替换为占位符。
            • 撤回与删除：可在「设置 → 关于 → 隐私政策」关闭单独同意；关闭后不再生成或比对声纹。已有声纹不会自动删除，可在「设置 → 声纹库」逐条删除。删除声纹不影响已生成的转写文本。拒绝或撤回不影响录音、转写、总结与待办等其余功能。
            """,
            separateConsent: true
        ),
        Section(
            "cloud",
            "云端处理与网络传输",
            """
            以下功能会联网；云端模型需要你自行配置：

            • 云端转写：音频上传到你配置的转写服务（如 OpenAI）。上传的是音频本身，无法做文本脱敏。
            • 云端大模型：转写文本上传到你配置的模型服务。发送前会在本机做 PII 去标识化（人名、公司、账号、手机号、身份证号、邮箱等替换为占位符），收到结果后在本地还原。
            • 云端视觉模型：截图与关键帧会上传；画面本身不做脱敏，请先确认画面中不含敏感信息。
            • 模型下载：从 Hugging Face、GitHub 下载本地语音与说话人分离模型。该过程只下载模型文件，不上传你的内容。
            • 应用更新：同意本政策后，应用通过 Sparkle 从 GitHub 获取 Memozia 更新信息，默认自动检查，也可在设置中关闭自动检查或手动检查。请求会向 GitHub 发送网络连接所需的 IP 地址、应用版本及操作系统版本；不发送录音、笔记、API Key 或其他会议内容，关闭系统画像。更新包从 GitHub 下载并验证签名，安装前需要你确认；录音、录屏或处理任务进行中时会延后安装。

            iCloud：本应用当前未启用 iCloud / CloudKit 同步，不会主动把数据写入 iCloud。若你的 macOS 开启了「桌面与文稿」iCloud 云盘同步，~/Documents/Memozia 可能被系统同步到 iCloud；这由你的系统设置决定，可在「系统设置 → Apple 账户 → iCloud」中关闭。

            跨境传输：你配置的云端服务可能位于你所在国家/地区之外，使用这些服务可能构成个人信息跨境传输。请自行确认服务商的隐私政策与所在地法律要求；对敏感内容，建议优先使用本地模式。
            """
        ),
        Section(
            "storage",
            "数据存储与保留期限",
            """
            • 数据文件夹：默认 ~/Documents/Memozia/，按 yyyy-MM 月份归档到子文件夹；你可以在「设置 → 数据管理 → 数据文件夹」改为其他位置，切换后需要重启应用，旧数据不会自动迁移。
            • 声纹固定保存在 ~/Documents/Memozia/Voiceprints/，不随自定义数据文件夹移动。
            • 转写、总结与待办以加密形式保存在本机数据库与条目文件夹中；加密密钥保存在 macOS 钥匙串（Keychain）。
            • 原始音频、视频、图片与手动导出的文件不额外加密，请妥善保护数据文件夹及其备份。
            • 兼容读取旧版明文数据。加密失败时会提示；部分内容可能回退为明文保存，请根据提示检查本机存储与钥匙串状态。
            • API Key 保存在 Keychain，不写入普通偏好设置或日志。
            • 声纹文件为 JSON 明文，未额外加密（见「声纹」一节）。
            • 保留期限：数据保存在你的 Mac 上，直至你自行删除。我们不在服务端保存你的副本；你配置的第三方云端服务如何保留数据，受其隐私政策约束。
            • 卸载应用不会自动删除数据文件夹、本地数据库与 Keychain 项目，需要你手动清理。
            • 你使用 Time Machine、iCloud 云盘或其他备份工具产生的副本，受相应工具与系统设置控制。
            """
        ),
        Section(
            "sharing",
            "共享、转让与公开披露",
            """
            • 我们不出售、不出租你的个人信息，也不会为营销目的向你以外的第三方共享。
            • 数据外发包括上文披露的云端处理、模型下载、更新检查与安装包下载，以及你主动通过系统邮件应用发送的反馈；相应请求直接发往对应服务，不经过我们的内容处理服务器。
            • 除法律法规要求或司法机关依法调取外，我们不会披露你的数据。
            • 如发生合并、收购等情形，我们会要求承继方继续受本政策约束，并在必要时重新征得你的同意。
            """
        ),
        Section(
            "security",
            "安全措施",
            """
            • 本机转写、总结与待办默认使用 AES-GCM 加密，密钥托管在系统钥匙串；原始媒体、导出文件、旧版明文与加密失败回退内容的边界见「数据存储与保留期限」。
            • 发往云端大模型的文本会先做 PII 去标识化。
            • 音频、截图与视频帧无法做文本脱敏；使用云端转写或云端视觉前，请自行判断内容的敏感程度。
            • 「配置迁移」导出的文件含 API Key，已用本机密钥加密，且只能在本机导入，请妥善保管。
            • 若发现数据安全事件，我们会通过应用内提示告知，并按法律要求处理。
            """
        ),
        Section(
            "rights",
            "你的权利",
            """
            • 访问与复制：在 Finder 中打开数据文件夹即可查看与备份，也可使用应用内导出功能。
            • 更正：直接编辑转写、总结与待办。
            • 删除：逐条删除录音及关联内容，或整体删除数据文件夹。
            • 撤回同意：在「设置 → 关于 → 隐私政策」撤回隐私同意（应用将退出，并在下次启动时重新征求同意）；声纹可以单独撤回。
            • 投诉与咨询：\(contactDescription) 你也可以向所在地个人信息保护监管部门投诉。

            我们会在合理期限内回复你的请求。
            """
        ),
        Section(
            "minors",
            "未成年人",
            """
            本应用面向成年职场用户。若你未满 18 周岁，请在监护人同意并指导下使用；我们不面向未满 14 周岁的儿童提供服务，若你未满 14 周岁，请由监护人代为同意并指导使用。

            监护人如发现儿童在未经同意的情况下使用了本应用，可在本机删除相关数据；公开发布后也可通过应用公示的联系渠道提出请求。
            """
        ),
        Section(
            "changes",
            "政策变更",
            """
            • 当前版本 \(version)，生效日期 \(effectiveDate)。
            • 实质性变更（新增数据类别、新增数据外发路径、改变处理目的）会提升主版本号，并在启动时重新征求你的同意。
            • 非实质性修订（措辞与排版调整）只更新次版本号，不重复征求同意，但会在应用内标注最新版本与生效日期。
            • 你可以在「设置 → 关于 → 隐私政策」随时查看当前版本。
            """
        ),
        Section(
            "ai",
            "AI 生成内容的边界",
            """
            总结、待办与画面要点由模型自动生成，可能存在错误或遗漏，仅供参考，不构成法律、医疗、财务等专业意见。涉及重要决策时，请自行核实原始录音与文本。
            """
        ),
        Section(
            "contact",
            "联系我们",
            """
            如对本政策或个人信息处理有疑问、意见或投诉：

            \(contactDescription)

            配置联系渠道后，发布方会在合理期限内回复。
            """
        )
    ]

    // MARK: - 同意状态

    enum StorageKey {
        /// 旧布尔开关；保留以兼容历史安装，但判断是否需要同意时必须同时比对版本
        static let accepted = "hasAcceptedPrivacyPolicy"
        static let acceptedAt = "privacyPolicyAcceptedDate"
        static let acceptedVersion = "privacyPolicyVersion"
        /// 声纹等敏感个人信息的单独同意
        static let voiceprintConsent = "voiceprintConsentGranted"
    }

    /// 已同意的政策版本；从未同意过或旧版本用户为 nil
    static func storedVersion(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: StorageKey.acceptedVersion)
    }

    static func acceptedDate(defaults: UserDefaults = .standard) -> Date? {
        let stamp = defaults.double(forKey: StorageKey.acceptedAt)
        guard stamp > 0 else { return nil }
        return Date(timeIntervalSince1970: stamp)
    }

    /// 取主版本号（“2.1” → “2”）。无法解析时返回原值，保证不同版本一定会重新同意。
    static func majorVersion(of version: String) -> String {
        version.split(separator: ".").first.map(String.init) ?? version
    }

    /// 纯函数版：便于测试，也避免视图在 body 里直接读 UserDefaults。
    ///
    /// 规则：
    /// - 未同意 → 需要同意
    /// - 同意过但没记录版本（旧安装）→ 需要同意
    /// - 主版本号变化 → 需要同意；仅次版本号变化 → 不重复打扰
    static func needsConsent(accepted: Bool, storedVersion: String?) -> Bool {
        guard accepted else { return true }
        guard let storedVersion, !storedVersion.isEmpty else { return true }
        return majorVersion(of: storedVersion) != majorVersion(of: version)
    }

    /// 是否需要（重新）展示同意页。
    static func needsConsent(defaults: UserDefaults = .standard) -> Bool {
        needsConsent(
            accepted: defaults.bool(forKey: StorageKey.accepted),
            storedVersion: storedVersion(defaults: defaults)
        )
    }

    /// 记录同意。`voiceprintConsent` 为 nil 表示本次不改动声纹的单独同意状态。
    static func accept(
        voiceprintConsent: Bool? = nil,
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        defaults.set(true, forKey: StorageKey.accepted)
        defaults.set(date.timeIntervalSince1970, forKey: StorageKey.acceptedAt)
        defaults.set(version, forKey: StorageKey.acceptedVersion)
        if let voiceprintConsent {
            defaults.set(voiceprintConsent, forKey: StorageKey.voiceprintConsent)
        }
    }

    /// 撤回同意（「设置 → 关于 → 隐私政策」的撤回入口用）。
    /// 同时清掉声纹单独同意：总体同意都撤回了，敏感信息也不应继续处理。
    static func revoke(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: StorageKey.accepted)
        defaults.removeObject(forKey: StorageKey.acceptedAt)
        defaults.removeObject(forKey: StorageKey.acceptedVersion)
        defaults.set(false, forKey: StorageKey.voiceprintConsent)
    }

    static func voiceprintConsentGranted(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: StorageKey.voiceprintConsent)
    }

    /// 设置声纹单独同意（设置页开关用；不影响总体同意状态）
    static func setVoiceprintConsent(_ granted: Bool, defaults: UserDefaults = .standard) {
        defaults.set(granted, forKey: StorageKey.voiceprintConsent)
    }
}
