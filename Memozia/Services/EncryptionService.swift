import Foundation
import CryptoKit
import KeychainAccess
import SwiftData
import os.log

/// 数据加密服务
/// 使用 AES-GCM 256 加密敏感数据（转写文本、总结内容）
/// 加密密钥存储在 Keychain 中，设备唯一
enum EncryptionService {

    /// Keychain 服务名
    private static let keychainService = "app.memozia.encryption"
    /// 密钥存储键
    private static let keychainKey = "encryption_key"

    /// 加密链路日志（失败留痕用）
    private static let encryptionLogger = Logger(subsystem: "app.memozia", category: "Encryption")

    /// 密钥锁：保护 cachedKey 与首次创建流程，避免并发首次调用各自生成密钥互相覆盖
    /// （一旦覆盖，用旧密钥加密的数据将永久不可读）
    private static let keyLock = NSLock()
    /// 内存缓存的密钥（避免每次加解密都访问 Keychain），
    /// 用 @unchecked Sendable 盒子包装以满足 Swift 6 全局可变状态检查，实际由 keyLock 保护
    private static let keyBox = KeyBox()

    private final class KeyBox: @unchecked Sendable {
        var key: SymmetricKey?
    }

    /// 解密结果缓存（key = 密文，value = 明文；同一密文解密结果恒定）
    /// NSCache 线程安全且内存压力下自动驱逐。
    /// 动机：列表页每行的状态标签（未总结/已总结）与文字预览在每次视图刷新时
    /// 都会触发 decryptedSummary/decryptedTextContent 解密，滚动/选中即产生
    /// 数十次 AES-GCM 运算；缓存命中后降为一次字典查找
    private static let decryptCacheBox = DecryptCacheBox()

    private final class DecryptCacheBox: @unchecked Sendable {
        let cache = NSCache<NSString, NSString>()
        init() {
            // 明文总缓存上限 32MB（cost = 明文 UTF8 字节数）
            cache.totalCostLimit = 32 * 1024 * 1024
        }
    }

    // MARK: - 密钥管理

    /// 获取或创建加密密钥
    ///
    /// 安全说明：
    /// - 首次运行时创建新密钥并存储到 Keychain（加锁 + 双重检查，防止并发竞态覆盖密钥）
    /// - 后续运行从 Keychain 读取已有密钥，并缓存到内存
    /// - Keychain 读取失败时抛出错误而非静默创建新密钥（避免密钥轮换导致旧数据不可读）
    private static func getOrCreateKey() throws -> SymmetricKey {
        keyLock.lock()
        defer { keyLock.unlock() }

        // 命中内存缓存
        if let cached = keyBox.key {
            return cached
        }

        #if DEBUG
        // 显式隔离的测试进程不访问用户 Keychain；Release 不编译此分支。
        if AppRuntime.isRunningTests,
           ProcessInfo.processInfo.environment["MEMOZIA_EPHEMERAL_TEST_ENCRYPTION"] == "1" {
            let key = SymmetricKey(size: .bits256)
            keyBox.key = key
            return key
        }
        #endif

        let keychain = Keychain(service: keychainService).accessibility(.afterFirstUnlock)

        // 尝试从 Keychain 读取
        do {
            if let keyData = try keychain.getData(keychainKey) {
                let key = SymmetricKey(data: keyData)
                keyBox.key = key
                return key
            }
        } catch {
            // Keychain 读取出错（非"条目不存在"），抛出错误避免静默轮换密钥
            // 用户已有加密数据会因新密钥而永久不可读
            throw EncryptionError.keychainReadFailed(error.localizedDescription)
        }

        // Keychain 中不存在密钥（首次运行或全新安装），创建新密钥
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        do {
            try keychain.set(keyData, key: keychainKey)
        } catch {
            // 密钥落盘失败：不缓存、不返回，避免"仅存于内存"的密钥丢失后数据不可读
            throw EncryptionError.encryptionFailed
        }
        keyBox.key = newKey
        return newKey
    }

    // MARK: - 文本加密/解密

    /// 加密文本
    /// - Parameter plaintext: 明文
    /// - Returns: Base64 编码的密文（含 nonce 和 tag）
    static func encrypt(_ plaintext: String) throws -> String {
        do {
            return try encryptUnchecked(plaintext)
        } catch {
            // 加密失败在单一入口留痕：各调用点普遍用 `try?`/catch 回退存明文，
            // 只写局部日志时“已开启加密”的 UI 与磁盘实际明文会不一致且永不显现
            reportEncryptionFailure(error)
            throw error
        }
    }

    private static func encryptUnchecked(_ plaintext: String) throws -> String {
        guard !plaintext.isEmpty else { return "" }

        let key = try getOrCreateKey()
        let plaintextData = Data(plaintext.utf8)
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(plaintextData, using: key, nonce: nonce)

        // combined = nonce(12 bytes) + ciphertext + tag(16 bytes)
        guard let combined = sealedBox.combined else {
            throw EncryptionError.encryptionFailed
        }

        return combined.base64EncodedString()
    }

    /// 解密文本
    /// - Parameter ciphertext: Base64 编码的密文
    /// - Returns: 明文
    static func decrypt(_ ciphertext: String) throws -> String {
        guard !ciphertext.isEmpty else { return "" }

        let key = try getOrCreateKey()
        guard let combinedData = Data(base64Encoded: ciphertext) else {
            throw EncryptionError.invalidCiphertext
        }

        let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
        let decryptedData = try AES.GCM.open(sealedBox, using: key)

        guard let plaintext = String(data: decryptedData, encoding: .utf8) else {
            throw EncryptionError.decryptionFailed
        }

        return plaintext
    }

    /// 安全解密（向后兼容明文存储）
    /// - 非 Base64 内容：视为加密失败时回退存储的明文，原样返回（保证明文数据可读）
    /// - Base64 但解密失败：说明是损坏/密钥不匹配的密文，返回空字符串（不能把密文当明文展示），
    ///   并触发一次性解密失败通知（每次启动最多一条，供 UI 提示用户密钥可能已更改）
    /// - 结果按密文缓存：同一密文重复解密（列表刷新/视图重算）直接命中缓存
    static func decryptSafely(_ ciphertext: String?) -> String {
        guard let ciphertext = ciphertext, !ciphertext.isEmpty else {
            return ""
        }
        let cacheKey = ciphertext as NSString
        if let cached = decryptCacheBox.cache.object(forKey: cacheKey) {
            return cached as String
        }
        // 合法的加密输出必然是 Base64；不满足则说明是明文回退数据，原样返回
        guard Data(base64Encoded: ciphertext) != nil else {
            decryptCacheBox.cache.setObject(
                ciphertext as NSString,
                forKey: cacheKey,
                cost: ciphertext.utf8.count
            )
            return ciphertext
        }
        if let decrypted = try? decrypt(ciphertext) {
            decryptCacheBox.cache.setObject(
                decrypted as NSString,
                forKey: cacheKey,
                cost: decrypted.utf8.count
            )
            return decrypted
        }
        markDecryptionFailureIfNeeded(ciphertext)
        return ""
    }

    // MARK: - 解密失败检测（一次性 UI 提示）

    /// 解密失败检测通知：Base64 合法但解密失败（密钥更改/密文损坏）时发出，每次启动最多一次
    static let decryptionFailureNotification = Notification.Name("MemoziaDecryptionFailureDetected")

    /// 加密失败通知：加密抛错（多数调用点会回退为明文存储）时发出，每次启动最多一次。
    /// 与解密失败分开展示：两者原因与处置方式不同（密钥丢失 vs Keychain 不可用）
    static let encryptionFailureNotification = Notification.Name("MemoziaEncryptionFailureDetected")

    private static let failureNoticeLock = NSLock()
    /// 已发过失败通知的标记（Swift 6 下可变全局状态用 Box 包装，由 failureNoticeLock 保护）
    private static let failureNoticeBox = FailureNoticeBox()

    private final class FailureNoticeBox: @unchecked Sendable {
        var decryptionPosted = false
        var encryptionPosted = false
    }

    /// 登记一次加密失败（日志 + 每启动最多一条通知），不改变调用方的错误语义
    /// - Parameter context: 失败内容的中文说明（如"转写片段"），仅进日志便于定位
    static func reportEncryptionFailure(_ error: any Error, context: String = "") {
        let label = context.isEmpty ? "加密失败" : "\(context)加密失败"
        encryptionLogger.fault("\(label, privacy: .public)（调用点可能回退为明文存储）: \(error.localizedDescription)")
        failureNoticeLock.lock()
        let alreadyPosted = failureNoticeBox.encryptionPosted
        failureNoticeBox.encryptionPosted = true
        failureNoticeLock.unlock()
        guard !alreadyPosted else { return }
        Task { @MainActor in
            NotificationCenter.default.post(name: encryptionFailureNotification, object: nil)
        }
    }

    /// 仅对“疑似密文”报警：AES-GCM combined 最短为 28 字节（nonce 12 + tag 16），
    /// Base64 解码不足 28 字节的多为碰巧合法的短明文，避免误报
    private static func markDecryptionFailureIfNeeded(_ ciphertext: String) {
        guard let data = Data(base64Encoded: ciphertext), data.count >= 28 else { return }
        failureNoticeLock.lock()
        let alreadyPosted = failureNoticeBox.decryptionPosted
        failureNoticeBox.decryptionPosted = true
        failureNoticeLock.unlock()
        guard !alreadyPosted else { return }
        Task { @MainActor in
            NotificationCenter.default.post(name: decryptionFailureNotification, object: nil)
        }
    }

    // MARK: - 文件内容加密/解密（用于磁盘文件加密存储）

    /// 加密文本并写入文件（磁盘文件加密存储）
    /// - Parameters:
    ///   - plaintext: 明文内容
    ///   - url: 目标文件 URL
    static func encryptAndWrite(_ plaintext: String, to url: URL) throws {
        let encrypted = try encrypt(plaintext)
        try encrypted.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// 从文件读取并解密，兼容旧版明文文件。
    ///
    /// 非 Base64（或短到不可能是 AES-GCM combined）的内容才允许按旧版明文返回；
    /// 足以构成 AES-GCM 密文的 Base64 内容若解密失败，说明密钥不匹配或文件损坏，
    /// 必须返回 nil 并沿用一次性告警，不能把密文当明文再次加密进数据库。
    /// - Parameter url: 文件 URL
    /// - Returns: 解密后的明文内容
    static func decryptFileOrPlaintext(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // 尝试解密
        if let decrypted = try? decrypt(text) {
            return decrypted
        }
        if let data = Data(base64Encoded: text), data.count >= 28 {
            markDecryptionFailureIfNeeded(text)
            return nil
        }
        // 旧版明文，或碰巧是短 Base64 的普通文本
        return text
    }

    // MARK: - 文件加密/解密

    /// 对外读取必须区分“没有内容”与“密文无法解开”，沿用明文兼容和失败告警。
    static func decryptForExternalAccess(_ value: String?) throws -> String {
        guard let value, !value.isEmpty else { return "" }
        guard value.utf8.count <= 4 * 1024 * 1024 else { throw MCPQueryError.responseTooLarge }
        guard let data = Data(base64Encoded: value), data.count >= 28 else { return value }
        do { return try decrypt(value) }
        catch {
            markDecryptionFailureIfNeeded(value)
            throw MCPQueryError.readFailed
        }
    }

    /// 加密文件内容并写入磁盘
    /// - Parameters:
    ///   - sourceURL: 源文件 URL
    ///   - destinationURL: 目标文件 URL
    static func encryptFile(at sourceURL: URL, to destinationURL: URL) throws {
        let key = try getOrCreateKey()
        let plaintextData = try Data(contentsOf: sourceURL)
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(plaintextData, using: key, nonce: nonce)

        guard let combined = sealedBox.combined else {
            throw EncryptionError.encryptionFailed
        }

        try combined.write(to: destinationURL, options: .atomic)
    }

    /// 解密文件内容
    /// - Parameter encryptedURL: 加密文件 URL
    /// - Returns: 解密后的 Data
    static func decryptFile(at encryptedURL: URL) throws -> Data {
        let key = try getOrCreateKey()
        let combinedData = try Data(contentsOf: encryptedURL)
        let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
        return try AES.GCM.open(sealedBox, using: key)
    }

    // MARK: - 数据迁移

    /// 迁移分页大小：旧实现一次 fetch 全表并在末尾单次 save，
    /// 大库首次迁移会把所有录音及其全部片段一次性物化到主线程内存里
    private static let migrationPageSize = 20

    /// 迁移现有数据：加密所有未加密的转写文本和总结
    ///
    /// 性能设计：SwiftData 模型只能在 MainActor 触碰，但加解密是纯函数且线程安全——
    /// 主线程只做密文快照与写回，isEncrypted 探测与 encrypt 全部移入后台任务，
    /// 避免大库首次迁移时主线程持续做 AES 运算。
    ///
    /// 分页 + 每页 save + 游标续跑：单页内存可控，且中途退出后从游标继续，
    /// 不再"每次冷启动都从第一条重扫整库"（迁移本身幂等，游标只做吞吐优化）。
    @MainActor
    static func migrateEncryption(context: ModelContext) async throws {
        let migrationKey = "encryption_migration_completed"
        let cursorKey = "encryption_migration_cursor"
        let defaults = UserDefaults.standard

        // 检查是否已完成迁移
        if defaults.bool(forKey: migrationKey) {
            return
        }

        // 预先创建密钥
        _ = try getOrCreateKey()

        var offset = defaults.integer(forKey: cursorKey)
        while true {
            var descriptor = FetchDescriptor<AudioRecording>(
                sortBy: [SortDescriptor(\.createdAt)]
            )
            descriptor.fetchLimit = migrationPageSize
            descriptor.fetchOffset = offset
            let page = try context.fetch(descriptor)
            guard !page.isEmpty else { break }

            var changedInPage = false
            for recording in page {
                if try await migrate(recording) {
                    changedInPage = true
                }
            }

            // 每页提交一次：避免整库变更压在最后一次 save 上（旧写法中途退出即全部重来）
            if changedInPage {
                try context.save()
            }
            offset += page.count
            defaults.set(offset, forKey: cursorKey)

            if page.count < migrationPageSize { break }
        }

        defaults.set(true, forKey: migrationKey)
        defaults.removeObject(forKey: cursorKey)
    }

    /// 迁移单条录音的总结与片段。返回本页是否有变更。
    @MainActor
    private static func migrate(_ recording: AudioRecording) async throws -> Bool {
        // 主线程快照：仅取密文，不做任何加密运算
        let summaryCipher = recording.summary
        let segmentPairs: [(id: UUID, text: String)] = recording.segments.map {
            (id: $0.id, text: $0.text)
        }
        guard summaryCipher?.isEmpty == false || !segmentPairs.isEmpty else { return false }

        // 后台批量加密：探测 + 加密均为纯函数。
        // 错误保持向上传播（与旧实现一致）：吞掉会让"迁移完成"标记被误置，
        // 未迁移的数据就此再也不会被处理
        let outcome: (summary: String?, segments: [(UUID, String)]) = try await Task.detached(priority: .userInitiated) {
                () throws -> (summary: String?, segments: [(UUID, String)]) in
                var encryptedSummary: String?
                if let summary = summaryCipher, !summary.isEmpty, !isEncrypted(summary) {
                    encryptedSummary = try encrypt(summary)
                }
                var encryptedSegments: [(UUID, String)] = []
                for (id, text) in segmentPairs where !text.isEmpty && !isEncrypted(text) {
                    encryptedSegments.append((id, try encrypt(text)))
                }
                return (summary: encryptedSummary, segments: encryptedSegments)
            }.value

        guard !outcome.segments.isEmpty || outcome.summary != nil else { return false }

        // 主线程写回
        if let newSummary = outcome.summary {
            recording.summary = newSummary
        }
        if !outcome.segments.isEmpty {
            var segmentByID: [UUID: TranscriptSegment] = [:]
            segmentByID.reserveCapacity(segmentPairs.count)
            for segment in recording.segments {
                segmentByID[segment.id] = segment
            }
            for (id, newText) in outcome.segments {
                segmentByID[id]?.text = newText
            }
        }
        // 让出主线程：页内逐条 yield，比旧版"每 5 条让出一次"更平滑
        await Task.yield()
        return true
    }

    /// 检查文本是否已加密（尝试解密，成功则已加密）
    /// 使用实际解密尝试替代 Base64 启发式判断，避免明文恰好满足 Base64 条件被误判
    private static func isEncrypted(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return (try? decrypt(text)) != nil
    }
}

// MARK: - 错误类型
enum EncryptionError: LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case invalidCiphertext
    case keyNotFound
    case keychainReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .encryptionFailed:   return String(localized: "数据加密失败")
        case .decryptionFailed:   return String(localized: "数据解密失败，密钥可能已更改")
        case .invalidCiphertext:  return String(localized: "无效的加密数据格式")
        case .keyNotFound:        return String(localized: "加密密钥未找到")
        case .keychainReadFailed(let detail): return String(format: String(localized: "加密密钥读取失败：%@。请勿删除 Keychain 中的密钥，否则已加密的数据将无法恢复。"), detail)
        }
    }
}
