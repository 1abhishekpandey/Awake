import Foundation

/// Display formatting shared by the views.
enum Format {
    /// `5h 12m`. Minutes are floored so the label never runs ahead of reality.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    /// Time of day in the user's locale, e.g. `6:40 PM` or `18:40`.
    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

extension Format {
    /// A time of day given as minutes after midnight, in the user's locale
    /// (`7:00 AM` or `07:00`). Built on a fixed date so a daylight-saving change
    /// on the current day can never make two options look the same.
    static func clock(minutesAfterMidnight minutes: Int) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let reference = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: minutes / 60, minute: minutes % 60))
        return (reference ?? .now).formatted(date: .omitted, time: .shortened)
    }
}
