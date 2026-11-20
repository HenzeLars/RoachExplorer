import Foundation

enum Format {
    /// Folders have no size.
    static let folderSize = "—"

    /// 1024-based, like Nautilus: "12 bytes", "4 KB", "1.2 MB".
    static func size(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return bytes == 1 ? "1 byte" : "\(bytes) bytes"
        }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1024
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let text = value < 10
            ? String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "")
            : String(format: "%.0f", value)
        return "\(text) \(units[index])"
    }

    /// Today: "10:41". Yesterday: "yesterday". This year: "Nov 3". Older: "Nov 3, 2023".
    static func date(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time.string(from: date) }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return monthDay.string(from: date)
        }
        return monthDayYear.string(from: date)
    }

    private static let locale = Locale(identifier: "en")

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "MMM d"
        return f
    }()

    private static let monthDayYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "MMM d, yyyy"
        return f
    }()
}
