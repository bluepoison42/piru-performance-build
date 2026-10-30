import Foundation

/// Returns the start of the user's "session day" for a given date.
///
/// Unlike `Calendar.startOfDay(for:)` (which always returns midnight), this
/// rolls late-night doses into the previous day's session so a journal entry
/// at 02:00 on Tuesday belongs to the session that started Monday afternoon.
///
/// The cutoff hour is stored in the shared App Group UserDefaults under
/// `dayBoundaryHour` so the main app, widgets, and Live Activity all agree
/// on where the day breaks. A value of 0 reproduces the classic midnight
/// behavior. Default is 4 AM.
///
/// `nonisolated`: pure date math over thread-safe `UserDefaults` reads, so it
/// stays callable off the main actor under the app target's default MainActor
/// isolation (the widget targets compile without that default, where this is
/// a no-op).
nonisolated extension Calendar {
    /// UserDefaults key used to persist the day-boundary hour across launches.
    static let dayBoundaryHourKey = "dayBoundaryHour"

    /// Hour (0-23) at which one session day ends and the next begins.
    /// Reads from the App Group suite so widgets see the same value the app
    /// is configured with.
    static var sessionDayBoundaryHour: Int {
        let suite = UserDefaults(suiteName: AppIdentity.appGroup)
        let stored = suite?.object(forKey: dayBoundaryHourKey) as? Int
        return stored.flatMap { (0 ... 12).contains($0) ? $0 : nil } ?? 4
    }

    /// Start of the session day containing `date`. If `date.hour` is before
    /// the configured boundary hour, returns the boundary hour on the previous
    /// calendar day; otherwise returns the boundary hour on the same day.
    func sessionDayStart(for date: Date) -> Date {
        let midnight = startOfDay(for: date)
        let boundary = medicationDayStart(forLabel: midnight)
        if date >= boundary { return boundary }
        let previous = self.date(byAdding: .day, value: -1, to: midnight) ?? midnight
        return medicationDayStart(forLabel: previous)
    }

    /// End at the next local boundary, including daylight-saving transitions.
    func sessionDayEnd(for date: Date) -> Date {
        let label = medicationDayLabel(for: date)
        let next = self.date(byAdding: .day, value: 1, to: label) ?? label.addingTimeInterval(86_400)
        return medicationDayStart(forLabel: next)
    }

    /// Midnight label for the medication day containing a real timestamp.
    func medicationDayLabel(for date: Date) -> Date {
        startOfDay(for: sessionDayStart(for: date))
    }

    /// A calendar cell is a day label, not an event at midnight.
    func medicationDayStart(forLabel date: Date) -> Date {
        self.date(bySettingHour: Self.sessionDayBoundaryHour, minute: 0, second: 0,
                  of: startOfDay(for: date)) ?? startOfDay(for: date)
    }

    /// Local clock minutes ordered from the configured day boundary.
    static func medicationClockMinutes(_ minutes: Int) -> Int {
        minutes < sessionDayBoundaryHour * 60 ? minutes + 1440 : minutes
    }

    /// A 02:00 slot on Monday's medication day fires on Tuesday morning.
    func medicationDayMoment(minutes: Int, onLabel label: Date) -> Date? {
        let day = startOfDay(for: label)
        let clockDay = minutes < Self.sessionDayBoundaryHour * 60
            ? (date(byAdding: .day, value: 1, to: day) ?? day) : day
        return date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: clockDay)
    }

    /// `shortWeekdaySymbols` rotated to start at `firstWeekday`.
    ///
    /// Foundation's `shortWeekdaySymbols` is **always** Sunday-first — index 0 is
    /// Sunday no matter what `firstWeekday` says. A month grid whose leading
    /// blanks are `(weekday - firstWeekday + 7) % 7` is therefore laid out
    /// Monday-first in most of Europe while its header still reads "Sun" over
    /// column 0, and every date appears one day early. That is the "calendar is
    /// a day behind" report; it is invisible in the US because `firstWeekday`
    /// is already 1 there.
    var orderedShortWeekdaySymbols: [String] {
        let symbols = shortWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let offset = (firstWeekday - 1 + 7) % 7
        return Array(symbols[offset...] + symbols[..<offset])
    }
}
