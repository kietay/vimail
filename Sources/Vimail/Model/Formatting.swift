import Foundation
import MailCore

enum Formatting {
    private static let time: DateFormatter = make("HH:mm")
    private static let weekday: DateFormatter = make("EEE")
    private static let monthDay: DateFormatter = make("MMM d")
    private static let short: DateFormatter = make("M/d/yy")
    private static let long: DateFormatter = make("EEE, MMM d, yyyy · HH:mm")
    private static let monthDayTime: DateFormatter = make("MMM d, HH:mm")
    private static let snooze: DateFormatter = make("EEE MMM d, HH:mm")

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = format
        return formatter
    }

    /// List timestamps, as in the design: "10:42", "Yesterday", "Mon", "Oct 3", "3/12/25".
    static func listDate(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7, days > 0 {
            return weekday.string(from: date)
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return monthDay.string(from: date) }
        return short.string(from: date)
    }

    static func readerTime(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? time.string(from: date) : monthDayTime.string(from: date)
    }

    static func longDate(_ date: Date) -> String { long.string(from: date) }
    static func snoozeDate(_ date: Date) -> String { snooze.string(from: date) }

    static func fileSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// "to me", "to Alex", "to me, Jamie +2"
    static func recipientsShort(_ message: MailMessage, me: Set<String>) -> String {
        let names = (message.to + message.cc).map { me.contains($0.normalized) ? "me" : $0.shortName }
        guard let first = names.first else { return "" }
        if names.count == 1 { return "to \(first)" }
        if names.count == 2 { return "to \(first), \(names[1])" }
        return "to \(first), \(names[1]) +\(names.count - 2)"
    }
}

/// Snooze presets and a tiny parser for typed snooze times ("2h", "3d", "mon", "tomorrow 9am").
enum SnoozeTimes {
    struct Preset: Identifiable {
        var id: String { key }
        var key: String
        var title: String
        var date: Date
    }

    static func presets(now: Date = Date()) -> [Preset] {
        let calendar = Calendar.current
        func at(_ hour: Int, daysFromNow days: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))!
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        }
        var presets: [Preset] = []
        let later = calendar.date(byAdding: .hour, value: 3, to: now)!
        presets.append(Preset(key: "l", title: "Later today", date: calendar.date(bySetting: .minute, value: 0, of: later) ?? later))
        if calendar.component(.hour, from: now) < 17 {
            presets.append(Preset(key: "e", title: "This evening", date: at(18, daysFromNow: 0)))
        }
        presets.append(Preset(key: "t", title: "Tomorrow", date: at(8, daysFromNow: 1)))
        let weekday = calendar.component(.weekday, from: now) // 1 = Sunday
        let daysToSaturday = (7 - weekday + 7) % 7
        if daysToSaturday > 1 {
            presets.append(Preset(key: "w", title: "This weekend", date: at(9, daysFromNow: daysToSaturday)))
        }
        let daysToMonday = ((9 - weekday) % 7 == 0) ? 7 : (9 - weekday) % 7
        presets.append(Preset(key: "n", title: "Next week", date: at(8, daysFromNow: daysToMonday)))
        presets.append(Preset(key: "m", title: "Next month", date: at(8, daysFromNow: 30)))
        return presets
    }

    /// Parses "45m", "2h", "3d", "1w", "tomorrow", "mon".."sun", optionally followed by "9am"/"14:00".
    static func parse(_ text: String, now: Date = Date()) -> Date? {
        let calendar = Calendar.current
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        if let unit = first.last, let amount = Int(first.dropLast()), amount > 0 {
            switch unit {
            case "m": return calendar.date(byAdding: .minute, value: amount, to: now)
            case "h": return calendar.date(byAdding: .hour, value: amount, to: now)
            case "d": return withTime(calendar.date(byAdding: .day, value: amount, to: now)!, words.dropFirst().first, defaultHour: 8)
            case "w": return withTime(calendar.date(byAdding: .day, value: 7 * amount, to: now)!, words.dropFirst().first, defaultHour: 8)
            default: break
            }
        }
        let days = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        if first == "tomorrow" || first == "tom" {
            return withTime(calendar.date(byAdding: .day, value: 1, to: now)!, words.dropFirst().first, defaultHour: 8)
        }
        if first == "today" || first == "tonight" {
            return withTime(now, words.dropFirst().first, defaultHour: first == "tonight" ? 20 : 17)
        }
        if let index = days.firstIndex(where: { first.hasPrefix($0) }) {
            let current = calendar.component(.weekday, from: now) - 1
            var delta = (index - current + 7) % 7
            if delta == 0 { delta = 7 }
            return withTime(calendar.date(byAdding: .day, value: delta, to: now)!, words.dropFirst().first, defaultHour: 8)
        }
        if let time = parseTime(first) {
            var date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: now)!
            if date <= now { date = calendar.date(byAdding: .day, value: 1, to: date)! }
            return date
        }
        return nil
    }

    /// `parse`, but only a time that is still ahead. Quick snooze text is typed once and used
    /// much later, when "tonight" or "today 5pm" may have passed.
    static func parseFuture(_ text: String, now: Date = Date()) -> Date? {
        guard let date = parse(text, now: now), date > now else { return nil }
        return date
    }

    private static func withTime(_ day: Date, _ word: String?, defaultHour: Int) -> Date? {
        let time = word.flatMap(parseTime) ?? (defaultHour, 0)
        return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day)
    }

    private static func parseTime(_ word: String) -> (hour: Int, minute: Int)? {
        var text = word
        var offset = 0
        if text.hasSuffix("am") { text.removeLast(2) } else if text.hasSuffix("pm") { text.removeLast(2); offset = 12 }
        let parts = text.split(separator: ":")
        guard let hour = Int(parts.first ?? ""), hour >= 0, hour <= 23 else { return nil }
        let minute = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let adjusted = offset == 12 && hour < 12 ? hour + 12 : (word.hasSuffix("am") && hour == 12 ? 0 : hour)
        return (adjusted, minute)
    }
}
