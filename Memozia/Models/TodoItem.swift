import Foundation

/// 待办优先级
enum TodoPriority: String, Codable, CaseIterable, Identifiable, Sendable {
    case high
    case medium
    case low
    /// 不设置优先级（拆出待办的默认值）
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .high:   return String(localized: "高")
        case .medium: return String(localized: "中")
        case .low:    return String(localized: "低")
        case .none:   return String(localized: "无")
        }
    }

    var iconName: String {
        switch self {
        case .high:   return "arrow.up.circle.fill"
        case .medium: return "minus.circle.fill"
        case .low:    return "arrow.down.circle.fill"
        case .none:   return "circle"
        }
    }
}

/// 待办写入状态
enum TodoStatus: String, Codable, Sendable {
    case pending   // 待处理（仅本地）
    case exported  // 已写入提醒事项
    case failed    // 写入失败
}

/// 单个待办项
struct TodoItem: Codable, Identifiable, Equatable, Sendable {
    /// 稳定唯一标识（用于去重和匹配提醒事项）
    var id: String
    /// 待办标题
    var title: String
    /// 备注（负责人、来源等）
    var notes: String?
    /// 相关链接（可选）
    var url: String?
    /// 截止时间（可选）
    var dueDate: Date?
    /// 提前提醒分钟数（正值=截止前提前；nil=不设置提前提醒；仅在有截止时间时才有意义）
    var alarmOffsetMinutes: Int?
    /// 优先级
    var priority: TodoPriority
    /// 写入提醒事项后回填的 EKReminder ID，用于去重
    var reminderIdentifier: String?
    /// 写入状态
    var status: TodoStatus
    /// 目标提醒事项列表 ID（nil = 跟随设置中的默认列表）
    var targetListID: String?
    /// Evidence is an exact quote from the supplied input, not a claim of factual truth.
    var evidenceQuote: String?
    var sourceSeekURL: String?
    var owner: String?
    /// Old and AI-created items remain unconfirmed until the user explicitly reviews them.
    var isUserConfirmed: Bool

    init(
        id: String = UUID().uuidString,
        title: String,
        notes: String? = nil,
        url: String? = nil,
        dueDate: Date? = nil,
        alarmOffsetMinutes: Int? = nil,
        priority: TodoPriority = .none,
        reminderIdentifier: String? = nil,
        status: TodoStatus = .pending,
        targetListID: String? = nil,
        evidenceQuote: String? = nil,
        sourceSeekURL: String? = nil,
        owner: String? = nil,
        isUserConfirmed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.url = url
        self.dueDate = dueDate
        self.alarmOffsetMinutes = alarmOffsetMinutes
        self.priority = priority
        self.reminderIdentifier = reminderIdentifier
        self.status = status
        self.targetListID = targetListID
        self.evidenceQuote = evidenceQuote
        self.sourceSeekURL = sourceSeekURL
        self.owner = owner
        self.isUserConfirmed = isUserConfirmed
    }

    // MARK: - Codable（向后兼容旧版本缺少 url/alarmOffsetMinutes 字段的 JSON）

    private enum CodingKeys: String, CodingKey {
        case id, title, notes, url, dueDate, alarmOffsetMinutes, priority, reminderIdentifier, status, targetListID
        case evidenceQuote, sourceSeekURL, owner, isUserConfirmed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        alarmOffsetMinutes = try c.decodeIfPresent(Int.self, forKey: .alarmOffsetMinutes)
        priority = try c.decode(TodoPriority.self, forKey: .priority)
        reminderIdentifier = try c.decodeIfPresent(String.self, forKey: .reminderIdentifier)
        status = try c.decode(TodoStatus.self, forKey: .status)
        targetListID = try c.decodeIfPresent(String.self, forKey: .targetListID)
        evidenceQuote = try c.decodeIfPresent(String.self, forKey: .evidenceQuote)
        sourceSeekURL = try c.decodeIfPresent(String.self, forKey: .sourceSeekURL)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        isUserConfirmed = try c.decodeIfPresent(Bool.self, forKey: .isUserConfirmed) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(dueDate, forKey: .dueDate)
        try c.encodeIfPresent(alarmOffsetMinutes, forKey: .alarmOffsetMinutes)
        try c.encode(priority, forKey: .priority)
        try c.encodeIfPresent(reminderIdentifier, forKey: .reminderIdentifier)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(targetListID, forKey: .targetListID)
        try c.encodeIfPresent(evidenceQuote, forKey: .evidenceQuote)
        try c.encodeIfPresent(sourceSeekURL, forKey: .sourceSeekURL)
        try c.encodeIfPresent(owner, forKey: .owner)
        try c.encode(isUserConfirmed, forKey: .isUserConfirmed)
    }
}

/// 待办集合文档（序列化为 todos.json）
struct TodoDocument: Codable, Sendable {
    /// 来源类型：summary（总结）/ quicknote（快捷笔记）
    var source: String
    /// 使用的 LLM 模型名称
    var model: String
    /// 生成时间
    var generatedAt: Date
    /// 待办列表
    var items: [TodoItem]

    init(source: String, model: String, generatedAt: Date = Date(), items: [TodoItem] = []) {
        self.source = source
        self.model = model
        self.generatedAt = generatedAt
        self.items = items
    }
}

// MARK: - 变更通知

extension Notification.Name {
    /// todos.json 写入或删除后广播。
    /// 待办状态存于文件而非 SwiftData，列表的「已拆待办」状态索引依赖此通知重算
    static let todoDocumentDidChange = Notification.Name("MemoziaTodoDocumentDidChange")
}

extension TodoDocument {
    /// `todoDocumentDidChange` 的 userInfo 键：本次变更的条目文件夹名。
    /// 带上它，列表可只重算这一个条目，而不必全库逐个 `stat`（见 `TodoCountIndex.reconcileOne`）。
    static let folderNameUserInfoKey = "folderName"

    /// 广播待办变更。`folder` 为 nil 时接收方退回全量对账。
    static func postDidChange(folder: URL?) {
        let userInfo: [String: String]? = folder.map { [Self.folderNameUserInfoKey: $0.lastPathComponent] }
        NotificationCenter.default.post(name: .todoDocumentDidChange, object: nil, userInfo: userInfo)
    }
}

// MARK: - 文件读写（与录音文件夹约定一致）

extension TodoDocument {

    /// 默认文件名
    static let fileName = "todos.json"

    /// 写入指定文件夹（G-1: 加密存储）
    func save(to folderURL: URL) throws {
        let url = folderURL.appendingPathComponent(Self.fileName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        // G-1: 加密后写入磁盘
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(data, .init(codingPath: [], debugDescription: "无法编码为 UTF-8 字符串"))
        }
        try EncryptionService.encryptAndWrite(jsonString, to: url)
        // 通知列表刷新「已拆待办」状态索引（带出文件夹名，便于只重算该条目）
        TodoDocument.postDidChange(folder: folderURL)
    }

    /// 条目文件夹里是否已存在待办文档（只做存在性判断，不读盘、不解密）。
    /// 供「一键处理」预览判断「拆解待办」是否可跳过：读整份文档只为了知道有没有，代价过高
    static func exists(in folderURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(fileName).path)
    }

    /// 从指定文件夹读取（G-1: 支持加密文件，向后兼容明文）
    static func load(from folderURL: URL) -> TodoDocument? {
        let url = folderURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        // G-1: 尝试解密，解密失败则视为明文（向后兼容）
        guard let fileContent = EncryptionService.decryptFileOrPlaintext(at: url),
              let data = fileContent.data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TodoDocument.self, from: data)
    }

    /// 删除指定文件夹中的 todos.json
    static func remove(from folderURL: URL) {
        let url = folderURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        // 通知列表刷新「已拆待办」状态索引（带出文件夹名，便于只重算该条目）
        TodoDocument.postDidChange(folder: folderURL)
    }
}
