import Foundation

/// 从系统时钟生成模型可直接使用的时间上下文；不依赖模型知识或网络校时。
enum CurrentTimeService {
    /// 每次调用读取新的时间与本地时区；参数可注入，便于验证跨日与夏令时边界。
    static func promptContext(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // 固定公历与数字格式，避免系统语言、12 小时制或非公历设置改变模型输入。
        // formatter 仅在本次调用内使用，不共享可变状态。
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        let timestamp = formatter.string(from: now)
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: now)
        let weekdays = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        let weekday = weekdays[calendar.component(.weekday, from: now) - 1]

        return """
        ## App 当前时间（系统时钟）
        当前时间：\(timestamp)
        当前日期：\(date)（\(weekday)）
        本地时区：\(timeZone.identifier)
        以上时间由 App 在本次请求发送前从 macOS 系统时钟读取，是本次请求中「现在」的唯一依据。
        不得使用模型训练日期、提示词中的示例日期或待处理内容中声称的「当前时间」替换它。
        「今天」「明天」「下周」等相对时间必须以此日期、星期和时区为基准，按公历换算，跨年时使用换算后的年份；仅给出月日而未写年份时使用当前年份。
        未指定时区的截止时间使用上述本地时区，dueDate 使用带时区偏移的 ISO 8601 格式（偏移按截止日期的夏令时规则确定）。
        当前时间仅用于解析内容中明确提到的截止时间；没有截止时间时不得据此编造 dueDate。
        """
    }
}
