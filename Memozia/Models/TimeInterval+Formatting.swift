import Foundation

/// 共享 `DateFormatter` 实例。
///
/// DateFormatter 构造极重（locale / 时区 / 日历解析），而列表行视图无复用：
/// 选中一项就会让所有可见行重算 body，旧写法每帧新建 formatter 是列表掉帧的
/// 直接原因之一。自 macOS 10.9 / iOS 7 起 NSDateFormatter 多线程使用是安全的，
/// 因此统一改为 `static let` 复用（配置与原逐次构造完全一致，不改显示行为）。
enum DateFormatters {
    /// 列表行无障碍标签的时间戳。
    ///
    /// 旧实现用固定模式 `formatter.dateFormat = "yyyy年MM月dd日 HH:mm"`：虽然模式本身
    /// 在 Catalog 里翻译过，但所有译文都把小时钉死为 24 小时制 `HH`，会无视用户在
    /// 「系统设置 → 日期与时间」里选择的 12/24 小时制与日期顺序。改用 dateStyle/timeStyle，
    /// 由系统按当前语言与用户偏好渲染。
    static let listRowTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

extension TimeInterval {
    /// 格式化为持续时间字符串
    /// - Parameters:
    ///   - forceHours: 为 true 时始终显示小时（如 "1:05:30"），为 false 时超过 1 小时才显示
    ///   - fractionDigits: 小数位数（0 = 整秒，1 = 0.1 秒，3 = 毫秒）。默认 0 保持既有整秒显示；
    ///     转写时间戳等需要亚秒精度的场景传 1
    /// - Returns: 格式化后的时间字符串
    func formattedAsDuration(forceHours: Bool = false, fractionDigits: Int = 0) -> String {
        let digits = max(0, fractionDigits)
        let scale = pow(10.0, Double(digits))

        // 录制刚启动时的时钟校正可能短暂给出负值；NaN/无穷大则会让
        // Double -> Int 直接 trap。显示层统一夹到可表示的非负整数，避免界面崩溃。
        let safe: Double
        if !isFinite || self <= 0 {
            safe = 0
        } else if self >= Double(Int.max) {
            safe = Double(Int.max)
        } else {
            safe = self
        }

        // 先按目标精度四舍五入再拆分：否则 59.97 这类值会被截成 59.9，丢掉进位
        let rounded = digits > 0 ? (safe * scale).rounded() / scale : safe
        let totalSeconds: Int
        if rounded >= Double(Int.max) {
            totalSeconds = Int.max
        } else {
            totalSeconds = Int(rounded)
        }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        let prefix = (hours > 0 || forceHours)
            ? "\(hours):" + String(format: "%02d:%02d", minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)

        guard digits > 0, totalSeconds < Int.max else { return prefix }
        let fraction = Int(((rounded - Double(totalSeconds)) * scale).rounded())
        return prefix + "." + String(format: "%0\(digits)d", fraction)
    }
}
