from pathlib import Path
import json
import re
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
old_id = "glass.kagerou.piru"
new_id = old_id + ".perftest"

query = root / "android/app/Sources/Piru/Android/SwiftDataUI.swift"
backup = root / "android/app/Sources/Piru/Android/Backup/FolderBackup+Android.swift"
assert "currentRevision" in query.read_text(encoding="utf-8"), "The query-cache fix is missing"
assert "captureBackup" in backup.read_text(encoding="utf-8"), "The background-backup fix is missing"

env = root / "android/app/Skip.env"
text = env.read_text(encoding="utf-8")
assert text.count("PRODUCT_BUNDLE_IDENTIFIER = " + old_id + "\n") == 1
env.write_text(text.replace("PRODUCT_BUNDLE_IDENTIFIER = " + old_id + "\n", "PRODUCT_BUNDLE_IDENTIFIER = " + new_id + "\n"), encoding="utf-8")

project = root / "Piru.xcodeproj/project.pbxproj"
text = project.read_text(encoding="utf-8")
text, identities = re.subn(r"(?m)(PIRU_BUNDLE_ID = )\"?glass\.kagerou\.piru\"?;", r"\1" + new_id + ";", text)
assert identities >= 1, "The native identity setting was not found"
text, versions = re.subn(r"MARKETING_VERSION = [\d.]+;", "MARKETING_VERSION = 1.5.1;", text)
text, builds = re.subn(r"CURRENT_PROJECT_VERSION = \d+;", "CURRENT_PROJECT_VERSION = 70004;", text)
assert versions and builds
project.write_text(text, encoding="utf-8")

manifest = root / "android/app/Android/app/src/main/AndroidManifest.xml"
text = manifest.read_text(encoding="utf-8")
assert 'android:label="${PRODUCT_NAME}"' in text
text = text.replace('android:label="${PRODUCT_NAME}"', 'android:label="Piru Perf Test"')
# The test app should not compete with the official app for normal Piru links.
text = re.sub(r"\s*<intent-filter\b[^>]*>.*?</intent-filter>", lambda match: "" if "android.intent.action.VIEW" in match.group() else match.group(), text, flags=re.S)
manifest.write_text(text, encoding="utf-8")
assert 'android:allowBackup="false"' in text
assert 'android:authorities="${applicationId}.files"' in text

shortcuts = root / "android/app/Android/app/src/main/res/xml/shortcuts.xml"
if shortcuts.exists():
    shortcuts.write_text(shortcuts.read_text(encoding="utf-8").replace(old_id, new_id), encoding="utf-8")

builder = root / "android/tools/build-app.sh"
text = builder.read_text(encoding="utf-8")
assert "--package-path . --build-system native" in text
builder.write_text(text.replace("--package-path . --build-system native", "--package-path . --build-system native --jobs 2"), encoding="utf-8")
for relative in ("android/tools/setup.sh", "android/tools/build-app.sh", "android/tools/package-apk.sh"):
    path = root / relative
    text = path.read_text(encoding="utf-8")
    text = text.replace('export JAVA_HOME=$(/usr/libexec/java_home -v 21)', 'export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}"')
    text = text.replace('/usr/libexec/java_home -v 21 > /dev/null 2>&1 || missing+=', '[[ -x "${JAVA_HOME}/bin/java" ]] || missing+=')
    path.write_text(text, encoding="utf-8")
plugin = root / "android/Compat/Plugins/StageSources/StageSources.swift"
text = plugin.read_text(encoding="utf-8")
old_python = 'URL(fileURLWithPath: "/usr/bin/python3")'
assert old_python in text
text = text.replace(old_python, "URL(fileURLWithPath: " + json.dumps(str(Path(sys.executable).resolve())) + ")")
plugin.write_text(text, encoding="utf-8")
print("Verified official fixes; isolated application ID:", new_id)

# The free Intel runner has 14 GB; keep Gradle and Kotlin in one bounded heap.
gradle = root / "android/app/Android/gradle.properties"
text = gradle.read_text(encoding="utf-8")
assert "org.gradle.jvmargs=-Xmx6g" in text and "kotlin.daemon.jvmargs=-Xmx8g" in text
text = text.replace("org.gradle.jvmargs=-Xmx6g", "org.gradle.jvmargs=-Xmx10g")
text = text.replace("kotlin.daemon.jvmargs=-Xmx8g", "kotlin.compiler.execution.strategy=in-process\norg.gradle.workers.max=2")
gradle.write_text(text, encoding="utf-8")

# SwiftPM otherwise selects a newer unpatched tag from the mirrored repository.
package = root / "android/app/Package.swift"
text = package.read_text(encoding="utf-8")
anchor = '.package(url: "https://github.com/skiptools/skip-fuse-ui.git", exact: "1.19.1"),'
assert anchor in text
text = text.replace(anchor, anchor + '\n        .package(url: "https://github.com/skiptools/skip-ui.git", exact: "1.64.0"),')
package.write_text(text, encoding="utf-8")
pin_check = root / "ci/perf/verify_pins.py"
pin_check.parent.mkdir(parents=True, exist_ok=True)
pin_check.write_text('''import ast, json, subprocess, sys
from pathlib import Path
stage = Path(sys.argv[1])
tool = Path(sys.argv[2])
tree = ast.parse(tool.read_text())
vendors = next(ast.literal_eval(node.value) for node in tree.body if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "VENDORED" for t in node.targets))
pins = {p["identity"].lower(): p["state"] for p in json.loads((stage / "Package.resolved").read_text())["pins"]}
for name, (_, _, version) in vendors.items():
    state = pins[name.lower()]
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=stage / "Vendor" / name, text=True).strip()
    assert state.get("version") == version and state["revision"] == revision, (name, state, version, revision)
print("Verified all patched dependency versions and revisions, including SkipUI 1.64.0")
''', encoding="utf-8")
builder = root / "android/tools/build-app.sh"
text = builder.read_text(encoding="utf-8")
anchor = 'xcrun swift package resolve --package-path . > "$PIRU_ANDROID/build/transpile.log" 2>&1'
assert anchor in text
text = text.replace(anchor, anchor + '\npython3 "$TOOLS/../../ci/perf/verify_pins.py" "$PIRU_ANDROID/stage" "$TOOLS/stage.py" || exit 1')
builder.write_text(text, encoding="utf-8")

# The medication checklist and quick-log chips must use the journal's day boundary.
calendar = root / "Shared/CalendarSessionDay.swift"
text = calendar.read_text(encoding="utf-8")
begin = text.index("        let cutoff = Self.sessionDayBoundaryHour\n", text.index("func sessionDayStart"))
end = text.index("\n    /// `shortWeekdaySymbols`", begin)
text = text[:begin] + '''        let midnight = startOfDay(for: date)
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
''' + text[end:]
calendar.write_text(text, encoding="utf-8")

def patch(relative, replacements):
    path = root / relative
    value = path.read_text(encoding="utf-8")
    for old, new in replacements:
        assert old in value, (relative, old)
        value = value.replace(old, new)
    path.write_text(value, encoding="utf-8")

patch("Piru/Data/Services/RoutineOccurrenceService.swift", [
    ("Calendar.current.startOfDay(for: now)", "Calendar.current.medicationDayLabel(for: now)"),
    ("let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)",
     "let dayStart = Calendar.current.medicationDayStart(forLabel: today)\n        let dayEnd = Calendar.current.sessionDayEnd(for: dayStart)"),
    ("$0.timestamp >= today &&", "$0.timestamp >= dayStart &&"),
])
patch("Piru/Views/Journal/DailyDose/MyMedsCard.swift", [
    ("Calendar.current.startOfDay(for: .now)", "Calendar.current.medicationDayLabel(for: .now)"),
    ("calendar.startOfDay(for: .now)", "calendar.medicationDayLabel(for: .now)"),
    ("let dayStart = Calendar.current.medicationDayLabel(for: .now)", "let dayStart = Calendar.current.sessionDayStart(for: .now)"),
])
patch("Piru/Views/Journal/DailyDose/MyMedsModel.swift", [
    ("AdherenceCalculator.isDue(item, on: .now)", "AdherenceCalculator.isDue(item, on: Calendar.current.medicationDayLabel(for: .now))"),
])
patch("Piru/Views/QuickLog/QuickLogModels.swift", [
    ("AdherenceCalculator.isDue(item, on: now)", "AdherenceCalculator.isDue(item, on: Calendar.current.medicationDayLabel(for: now))"),
    ("Calendar.current.isDateInToday(entry.timestamp)", "Calendar.current.medicationDayLabel(for: entry.timestamp) == Calendar.current.medicationDayLabel(for: .now)"),
])
patch("Piru/Views/QuickLog/Dock/DockIdleViews.swift", [
    ("calendar.startOfDay(for: now)", "calendar.sessionDayStart(for: now)"),
    ("AdherenceCalculator.isDue(item, on: now)", "AdherenceCalculator.isDue(item, on: calendar.medicationDayLabel(for: now))"),
])
patch("Piru/Utilities/AdherenceCalculator.swift", [
    ("let dayStart = calendar.startOfDay(for: date)", "let dayStart = calendar.medicationDayStart(forLabel: date)"),
    ("let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)", "let dayEnd = calendar.sessionDayEnd(for: dayStart)"),
    ("calendar.startOfDay(for: .now)", "calendar.medicationDayLabel(for: .now)"),
    ("calendar.startOfDay(for: $0.timestamp)", "calendar.medicationDayLabel(for: $0.timestamp)"),
    ("endingAt now: Date,", "endingAt timestamp: Date,"),
    ("guard let start = calendar.date(byAdding: .day, value: -dayCount, to: now)", "let now = calendar.medicationDayLabel(for: timestamp)\n        guard let start = calendar.date(byAdding: .day, value: -dayCount, to: now)"),
    ("times.count { $0 < noonMinutes }", "times.count { $0 >= Calendar.sessionDayBoundaryHour * 60 && $0 < noonMinutes }"),
    ("itemDoses.count { minutesOfDay($0.timestamp, calendar: calendar) < noonMinutes }", "itemDoses.count { let minutes = minutesOfDay($0.timestamp, calendar: calendar); return minutes >= Calendar.sessionDayBoundaryHour * 60 && minutes < noonMinutes }"),
])
patch("Piru/Utilities/AdherenceStreakStore.swift", [
    ("Calendar.current.startOfDay(for: .now)", "Calendar.current.medicationDayLabel(for: .now)"),
])
patch("Piru/Views/Insights/AdherenceModel.swift", [
    ("AdherenceCalculator.adherence(for: .now,", "AdherenceCalculator.adherence(for: calendar.medicationDayLabel(for: .now),"),
    ("calendar.startOfDay(for: entry.timestamp)", "calendar.medicationDayLabel(for: entry.timestamp)"),
])

patch("Piru/Data/Services/RoutineOccurrenceService.swift", [
    ("item.reminderTimesMinutes.sorted()", "item.reminderTimesMinutes.sorted { Calendar.medicationClockMinutes($0) < Calendar.medicationClockMinutes($1) }"),
    ("return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)", "return Calendar.medicationClockMinutes((parts.hour ?? 0) * 60 + (parts.minute ?? 0))"),
    ("return abs(minutes - slotMinutes)", "return abs(minutes - Calendar.medicationClockMinutes(slotMinutes))"),
])
patch("Piru/Views/Journal/DailyDose/MyMedsModel.swift", [
    ("item.reminderTimesMinutes.sorted()", "item.reminderTimesMinutes.sorted { Calendar.medicationClockMinutes($0) < Calendar.medicationClockMinutes($1) }"),
    ("($0.time ?? .max) < ($1.time ?? .max)", "($0.time.map(Calendar.medicationClockMinutes) ?? .max) < ($1.time.map(Calendar.medicationClockMinutes) ?? .max)"),
])
patch("Piru/Views/QuickLog/QuickLogModels.swift", [
    ("let nowMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)", "let nowMinutes = Calendar.medicationClockMinutes(calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now))"),
    ("item.reminderTimesMinutes.sorted()", "item.reminderTimesMinutes.sorted { Calendar.medicationClockMinutes($0) < Calendar.medicationClockMinutes($1) }"),
    ("guard slot <= nowMinutes + dueSoonLeadMinutes", "guard Calendar.medicationClockMinutes(slot) <= nowMinutes + dueSoonLeadMinutes"),
    ("($0.slotMinutes ?? .max, $0.item.sortOrder) < ($1.slotMinutes ?? .max, $1.item.sortOrder)", "($0.slotMinutes.map(Calendar.medicationClockMinutes) ?? .max, $0.item.sortOrder) < ($1.slotMinutes.map(Calendar.medicationClockMinutes) ?? .max, $1.item.sortOrder)"),
])
patch("Piru/Views/Journal/DailyDose/MyMedsInfo.swift", [
    ("let dueNow = pending.contains { ($0.minutes ?? 0) <= nowMinutes }", "let dueNow = pending.contains { $0.minutes.map { Calendar.medicationClockMinutes($0) <= Calendar.medicationClockMinutes(nowMinutes) } ?? true }"),
    (".filter({ $0.minutes > nowMinutes })", ".filter({ Calendar.medicationClockMinutes($0.minutes) > Calendar.medicationClockMinutes(nowMinutes) })"),
    (".min(by: { $0.minutes < $1.minutes })", ".min(by: { Calendar.medicationClockMinutes($0.minutes) < Calendar.medicationClockMinutes($1.minutes) })"),
])
dock = root / "Piru/Views/QuickLog/Dock/DockIdleViews.swift"
text = dock.read_text(encoding="utf-8")
start = text.index("    private static func nextMed(")
end = text.index("    private static func displayName(", start)
text = text[:start] + '''    private static func nextMed(items: [DailyDoseItem], todayEntries: [DoseEntry], now: Date, calendar: Calendar) -> DockMedRef? {
        let today = calendar.medicationDayLabel(for: now)
        var candidates: [(item: DailyDoseItem, at: Date)] = []
        for offset in 0 ... 1 {
            guard let label = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            for item in items where AdherenceCalculator.isDue(item, on: label) {
                let taken = offset == 0 ? todayEntries.count { AdherenceCalculator.entryMatches(entry: $0, item: item) } : 0
                let times = item.reminderTimesMinutes.sorted { Calendar.medicationClockMinutes($0) < Calendar.medicationClockMinutes($1) }
                for minutes in times.dropFirst(taken) {
                    if let at = calendar.medicationDayMoment(minutes: minutes, onLabel: label), at > now {
                        candidates.append((item, at))
                    }
                }
            }
        }
        guard let next = candidates.min(by: { $0.at < $1.at }) else { return nil }
        return DockMedRef(name: displayName(for: next.item), at: next.at)
    }

''' + text[end:]
dock.write_text(text, encoding="utf-8")
patch("Piru/Utilities/DoseNotificationManager.swift", [
    ("let today = calendar.startOfDay(for: now)", "let today = calendar.medicationDayLabel(for: now)"),
    ("let isToday = calendar.isDate(day, inSameDayAs: now)", "let isToday = day == calendar.medicationDayLabel(for: now)"),
    ("calendar.date(byAdding: .minute, value: time, to: day)", "calendar.medicationDayMoment(minutes: time, onLabel: day)"),
    ("guard let fireDate = calendar.date(byAdding: .minute, value: time + offset, to: day),", "guard let primary = calendar.medicationDayMoment(minutes: time, onLabel: day),\n                                  let fireDate = calendar.date(byAdding: .minute, value: offset, to: primary),\n                                  fireDate < calendar.sessionDayEnd(for: calendar.medicationDayStart(forLabel: day)),"),
    ("let todayStart = calendar.startOfDay(for: now)", "let todayStart = calendar.medicationDayLabel(for: now)"),
    ("guard let fireDate = calendar.date(byAdding: .minute, value: timeMinutes + offset, to: dayStart),", "guard let primary = calendar.medicationDayMoment(minutes: timeMinutes, onLabel: dayStart),\n                      let fireDate = calendar.date(byAdding: .minute, value: offset, to: primary),\n                      fireDate < calendar.sessionDayEnd(for: calendar.medicationDayStart(forLabel: dayStart)),"),
])

tests = root / "ci/perf/day-tests"
tests.mkdir(parents=True, exist_ok=True)
(tests / "Identity.swift").write_text('import Foundation\nnonisolated enum AppIdentity { static let appGroup = "piru.ci.day-boundary-tests" }\n', encoding="utf-8")
(tests / "main.swift").write_text('''import Foundation
let defaults = UserDefaults(suiteName: AppIdentity.appGroup)!
defer { defaults.removePersistentDomain(forName: AppIdentity.appGroup) }
func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!
defaults.set(4, forKey: Calendar.dayBoundaryHourKey)
let before = date("2026-05-22T03:59:59Z")
let boundary = date("2026-05-22T04:00:00Z")
assert(calendar.medicationDayLabel(for: before) == date("2026-05-21T00:00:00Z"))
assert(calendar.medicationDayLabel(for: boundary) == date("2026-05-22T00:00:00Z"))
let earlyDose = date("2026-05-22T02:00:00Z")
let yesterdayStart = calendar.medicationDayStart(forLabel: date("2026-05-21T00:00:00Z"))
let todayStart = calendar.medicationDayStart(forLabel: date("2026-05-22T00:00:00Z"))
assert(earlyDose >= yesterdayStart && earlyDose < calendar.sessionDayEnd(for: yesterdayStart))
assert(!(earlyDose >= todayStart && earlyDose < calendar.sessionDayEnd(for: todayStart)))
assert(calendar.sessionDayStart(for: earlyDose) == yesterdayStart)
defaults.set(0, forKey: Calendar.dayBoundaryHourKey)
assert(calendar.medicationDayLabel(for: earlyDose) == date("2026-05-22T00:00:00Z"))
defaults.set(4, forKey: Calendar.dayBoundaryHourKey)
calendar.timeZone = TimeZone(identifier: "America/Edmonton")!
// Spring/fall days have 23/25 hours; the boundary remains local 04:00.
for (start, end, hours) in [("2026-03-07T11:00:00Z", "2026-03-08T10:00:00Z", 23), ("2025-11-01T10:00:00Z", "2025-11-02T11:00:00Z", 25)] {
    let first = date(start), next = date(end)
    assert(calendar.sessionDayStart(for: first) == first)
    assert(calendar.sessionDayEnd(for: first) == next, "Boundary start \\(first); expected end \\(next); actual \\(calendar.sessionDayEnd(for: first)); zone \\(calendar.timeZone)")
    assert(Int(next.timeIntervalSince(first) / 3600) == hours)
    assert(calendar.component(.hour, from: next) == 4)
    assert(calendar.medicationDayLabel(for: next.addingTimeInterval(-1)) == calendar.startOfDay(for: first))
}
print("Medication day regression passed: 04:00 boundary, prior-night credit, midnight mode, DST 23/25-hour days.")
''', encoding="utf-8")
print("Prepared shared 04:00 medication-day fix and executable regression checks")

# Compile the actual pure notification function beside the real shared calendar code.
notification = (root / "Piru/Utilities/DoseNotificationManager.swift").read_text(encoding="utf-8")
start = notification.index("    nonisolated static func followUpFireDates(")
brace = notification.index("{", start)
depth = 1
end = brace + 1
while depth:
    depth += (notification[end] == "{") - (notification[end] == "}")
    end += 1
(tests / "NotificationScheduler.swift").write_text("import Foundation\nnonisolated enum ActualNotificationScheduler {\n" + notification[start:end] + "\n}\n", encoding="utf-8")
with (tests / "main.swift").open("a", encoding="utf-8") as test:
    test.write('''
calendar.timeZone = TimeZone(secondsFromGMT: 0)!
let night = date("2026-05-22T01:00:00Z")
let label = calendar.medicationDayLabel(for: night)
assert(label == date("2026-05-21T00:00:00Z"))
assert(calendar.medicationDayMoment(minutes: 120, onLabel: label) == date("2026-05-22T02:00:00Z"))
let tomorrow = calendar.date(byAdding: .day, value: 1, to: label)!
assert(calendar.medicationDayMoment(minutes: 1380, onLabel: tomorrow) == date("2026-05-22T23:00:00Z"))
assert(Calendar.medicationClockMinutes(120) > Calendar.medicationClockMinutes(1380))
let pending = ActualNotificationScheduler.followUpFireDates(timeMinutes: 1380, offsets: [180, 360], days: 2, skipToday: false, now: night, calendar: calendar)
assert(pending.map(\\.fireDate) == [date("2026-05-22T02:00:00Z"), date("2026-05-23T02:00:00Z")])
let taken = ActualNotificationScheduler.followUpFireDates(timeMinutes: 1380, offsets: [180], days: 2, skipToday: true, now: night, calendar: calendar)
assert(taken.map(\\.fireDate) == [date("2026-05-23T02:00:00Z")])
assert(pending.first!.dayKey == "20260521")
let overnightSlot = ActualNotificationScheduler.followUpFireDates(timeMinutes: 120, offsets: [0], days: 1, skipToday: false, now: night, calendar: calendar)
assert(overnightSlot.first!.fireDate == date("2026-05-22T02:00:00Z"))
print("Actual reminder regression passed: overnight slots, next evening, taken-day suppression and 04:00 expiry.")
''')

# Re-derive existing historical expectations, without applying today's schedule
# to the past or changing doses, timestamps, occurrence identities or user skips.
history_code = '''    /// A boundary change invalidates cached past-day matches, not user choices.
    /// Only existing expectations are recalculated; no past schedules are invented.
    nonisolated static func historicalPlan(
        occurrences: [OccurrenceSnapshot], entries: [EntrySnapshot]
    ) -> Plan {
        let items = occurrences.map {
            ItemSnapshot(substance: $0.substance, substanceUID: $0.substanceUID,
                         route: $0.route, slots: [$0.slotMinutes])
        }
        var result = plan(dueItems: items, occurrences: occurrences, expired: [], entries: entries)
        for row in occurrences {
            guard let outcome = result.updates[row.id] else { continue }
            let state: RoutineOccurrence.State = outcome.state == .pending ? .missed : outcome.state
            if row.state == state && row.satisfyingEntryID == outcome.satisfyingEntryID {
                result.updates.removeValue(forKey: row.id)
            } else {
                result.updates[row.id] = (state, outcome.satisfyingEntryID)
            }
        }
        return result
    }

    /// Mutates only derived states. The importer commits this with its other data.
    @discardableResult
    nonisolated static func repairHistoricalDays(in context: ModelContext, now: Date = .now) throws -> Int {
        let calendar = Calendar.current
        let today = calendar.medicationDayLabel(for: now)
        let predicate = #Predicate<RoutineOccurrence> { $0.dueDay < today }
        let rows = try context.fetch(FetchDescriptor(predicate: predicate))
        var changed = 0
        for (day, occurrences) in Dictionary(grouping: rows, by: \\.dueDay) {
            let start = calendar.medicationDayStart(forLabel: day)
            let end = calendar.sessionDayEnd(for: start)
            let entryPredicate = #Predicate<DoseEntry> { $0.timestamp >= start && $0.timestamp < end }
            let entries = try context.fetch(FetchDescriptor(predicate: entryPredicate))
            let snapshots = occurrences.map {
                OccurrenceSnapshot(id: $0.persistentModelID, substance: $0.substance,
                    substanceUID: $0.substanceUID, route: $0.route, slotMinutes: $0.slotMinutes,
                    state: $0.state, satisfyingEntryID: $0.satisfyingEntryID)
            }
            let entrySnapshots = entries.map {
                EntrySnapshot(id: $0.id, substance: $0.substance, substanceUID: $0.substanceUID,
                              route: $0.route, timestamp: $0.timestamp)
            }
            let result = historicalPlan(occurrences: snapshots, entries: entrySnapshots)
            for occurrence in occurrences {
                guard let outcome = result.updates[occurrence.persistentModelID] else { continue }
                occurrence.state = outcome.state
                occurrence.satisfyingEntryID = outcome.satisfyingEntryID
                changed += 1
            }
        }
        return changed
    }

    /// An upgrade repairs an already populated installation off the UI actor.
    @DatabaseActor
    static func repairHistoricalDays(container: ModelContainer, now: Date = .now) throws -> Int {
        let context = ModelContext(container)
        let changed = try repairHistoricalDays(in: context, now: now)
        if changed > 0 { try context.save() }
        return changed
    }

'''
service = root / "Piru/Data/Services/RoutineOccurrenceService.swift"
text = service.read_text(encoding="utf-8")
anchor = "    // MARK: - Snapshots"
assert text.count(anchor) == 1
text = text.replace(anchor, history_code + anchor)
service.write_text(text, encoding="utf-8")

importer = root / "Piru/Utilities/DataExportImport.swift"
text = importer.read_text(encoding="utf-8")
anchor = "        try commitImport(context: context)"
assert text.count(anchor) == 1
text = text.replace(anchor, "        if fileSettings != nil {\n            try RoutineOccurrenceService.repairHistoricalDays(in: context)\n        }\n\n" + anchor)
importer.write_text(text, encoding="utf-8")

launch = root / "android/app/Sources/Piru/Android/PiruAndroidApp.swift"
text = launch.read_text(encoding="utf-8")
anchor = "            await AppLaunch.finishLaunching(container: container)"
assert text.count(anchor) == 1
text = text.replace(anchor, anchor + '''
            let historyKey = "piru.medicationHistoryBoundary.v1"
            let boundary = Calendar.sessionDayBoundaryHour
            if UserDefaults.standard.object(forKey: historyKey) as? Int != boundary {
                do {
                    let changed = try await RoutineOccurrenceService.repairHistoricalDays(container: container)
                    UserDefaults.standard.set(boundary, forKey: historyKey)
                    if changed > 0 {
                        DoseLogService.shared.changed()
                        DoseNotificationManager.syncMedReminders(in: container.mainContext)
                    }
                } catch {
                    print("Piru: medication-day history repair failed; will retry next launch.")
                }
            }''')
launch.write_text(text, encoding="utf-8")

# Limit packaging to the application and its dependencies. The unqualified task
# also builds unused root-library copies alongside the included Skip modules.
packager = root / "android/tools/package-apk.sh"
text = packager.read_text(encoding="utf-8")
anchor = 'gradle "assemble${(C)${PIRU_CONFIG:-debug}}" --console=plain'
assert text.count(anchor) == 1
text = text.replace(anchor, 'gradle ":app:assemble${(C)${PIRU_CONFIG:-debug}}" --console=plain')
packager.write_text(text, encoding="utf-8")

# Exercise the actual production planner, not a second implementation.
def swift_member(text, anchor):
    start = text.index(anchor)
    brace = text.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]

service_text = service.read_text(encoding="utf-8")
anchors = ["nonisolated struct ItemSnapshot:", "nonisolated struct OccurrenceSnapshot:",
           "nonisolated struct EntrySnapshot:", "nonisolated struct Plan:",
           "nonisolated static func plan(\n", "nonisolated static func historicalPlan(",
           "private nonisolated static func corresponds(", "private nonisolated static func matches(",
           "private nonisolated static func minutesOfDay(", "private nonisolated static func distance("]
identity = swift_member((root / "Shared/MedSchedule.swift").read_text(encoding="utf-8"), "static func identityMatches(")
protocol = swift_member(service_text, "nonisolated protocol LiveOccurrence")
support = '''import Foundation
struct PersistentIdentifier: Hashable, Sendable { let value: String }
enum RouteOfAdministration: Sendable { case oral, subcutaneous }
enum RoutineOccurrence { enum State: Sendable { case pending, logged, missed, skipped } }
enum MedSchedule {\n''' + identity + "\n}\n" + protocol
support += "\nnonisolated enum ActualHistoryPlanner {\n" + "\n".join(swift_member(service_text, a) for a in anchors) + "\n}\n"
(tests / "HistoryPlanner.swift").write_text(support, encoding="utf-8")
with (tests / "main.swift").open("a", encoding="utf-8") as test:
    test.write('''
let occurrenceID = PersistentIdentifier(value: "existing")
let doseID = UUID()
let earlyTimestamp = date("2026-05-22T01:09:00Z")
let missed = ActualHistoryPlanner.OccurrenceSnapshot(id: occurrenceID, substance: "Guanfacine", substanceUID: "GUAN",
    route: .oral, slotMinutes: nil, state: .missed, satisfyingEntryID: nil)
let earlyEntry = ActualHistoryPlanner.EntrySnapshot(id: doseID, substance: "Guanfacine", substanceUID: "GUAN",
    route: .oral, timestamp: earlyTimestamp)
let repaired = ActualHistoryPlanner.historicalPlan(occurrences: [missed], entries: [earlyEntry])
assert(repaired.updates[occurrenceID]?.state == .logged)
assert(repaired.updates[occurrenceID]?.satisfyingEntryID == doseID)
assert(repaired.inserts.isEmpty && repaired.deletes.isEmpty && repaired.expire.isEmpty)
assert(earlyEntry.timestamp == earlyTimestamp)
let logged = ActualHistoryPlanner.OccurrenceSnapshot(id: occurrenceID, substance: "Guanfacine", substanceUID: "GUAN",
    route: .oral, slotMinutes: nil, state: .logged, satisfyingEntryID: doseID)
assert(ActualHistoryPlanner.historicalPlan(occurrences: [logged], entries: [earlyEntry]).isEmpty)
let wrongDay = ActualHistoryPlanner.historicalPlan(occurrences: [logged], entries: [])
assert(wrongDay.updates[occurrenceID]?.state == .missed)
assert(ActualHistoryPlanner.historicalPlan(occurrences: [missed], entries: []).isEmpty)
let skipped = ActualHistoryPlanner.OccurrenceSnapshot(id: occurrenceID, substance: "Guanfacine", substanceUID: "GUAN",
    route: .oral, slotMinutes: nil, state: .skipped, satisfyingEntryID: nil)
assert(ActualHistoryPlanner.historicalPlan(occurrences: [skipped], entries: [earlyEntry]).isEmpty)
let slotA = ActualHistoryPlanner.OccurrenceSnapshot(id: PersistentIdentifier(value: "night"), substance: "Guanfacine", substanceUID: "GUAN",
    route: .oral, slotMinutes: 1380, state: .missed, satisfyingEntryID: nil)
let slotB = ActualHistoryPlanner.OccurrenceSnapshot(id: PersistentIdentifier(value: "overnight"), substance: "Guanfacine", substanceUID: "GUAN",
    route: .oral, slotMinutes: 120, state: .missed, satisfyingEntryID: nil)
let slots = ActualHistoryPlanner.historicalPlan(occurrences: [slotA, slotB], entries: [earlyEntry])
assert(slots.updates.count == 1 && slots.updates[slotB.id]?.satisfyingEntryID == doseID)
print("Actual historical planner regression passed: prior-night credit, stale-day removal, sticky user skips, slot matching, no schedule creation and idempotence.")
''')
print("Prepared background history repair, import repair and actual production-planner regression checks")

# Android's Canvas compatibility layer creates a Compose node for every fill.
# Batch same-color, disjoint atom circles instead of creating one node per atom.
molecule = root / "Piru/Views/Library/MoleculeView.swift"
text = molecule.read_text(encoding="utf-8")
old = '''            let r = ballRadius * scale
            for index in shape.atoms.indices {
                guard let p = point(index) else { continue }
                context.fill(
                    Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                    with: .color(color),
                )
            }'''
new = '''            let r = ballRadius * scale
            var balls = Path()
            for index in shape.atoms.indices {
                guard let p = point(index) else { continue }
                balls.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            }
            context.fill(balls, with: .color(color))'''
assert text.count(old) == 1
molecule.write_text(text.replace(old, new), encoding="utf-8")

library = root / "Piru/Views/Library/LibraryBrowseView.swift"
text = library.read_text(encoding="utf-8")
for opacity, radius in (("0.3", "10"), ("0.45", "glowRadius"), ("0.35", "10")):
    old = f"content.shadow(color: color.opacity({opacity}), radius: {radius}, x: 0, y: 5)"
    new = f"content.background {{ shape.fill(color).shadow(color: color.opacity({opacity}), radius: {radius}, x: 0, y: 5) }}"
    assert text.count(old) == 1
    text = text.replace(old, new)
library.write_text(text, encoding="utf-8")

# Disjoint circles of the same color have identical coverage when batched,
# including transparent colors. Bundled coordinates and radii are unchanged.
import math
shapes = json.loads((root / "Piru/Data/MoleculeShapes.json").read_text(encoding="utf-8"))
assert len(shapes) == 12
minimum = min(math.dist(a, b) for s in shapes.values() for i, a in enumerate(s["atoms"]) for b in s["atoms"][i+1:])
assert minimum > 6.0, "Overlapping atom circles need a transparency-equivalence review"
assert "var ballRadius: CGFloat = 3.0" in molecule.read_text(encoding="utf-8")
assert molecule.read_text(encoding="utf-8").count("context.fill(") == 1
assert molecule.read_text(encoding="utf-8").count("context.stroke(") == 1
print(f"Library rendering verified: {len(shapes)} unchanged molecule shapes, minimum atom spacing {minimum:.5f} > diameter6; two Canvas nodes per molecule; shape-only outer shadows")

# Test the real generic decoder in isolation, before changing the application.
parser_tests = root / "ci/perf/parser-tests"
parser_tests.mkdir(parents=True, exist_ok=True)
persistence = root / "android/Compat/Sources/PortableData"
method = swift_member((persistence / "Snapshot.swift").read_text(encoding="utf-8"), "static func decode<T: Decodable>(_: T.Type, from raw:")
old_guard = "if let primitive = T.self as? any PrimitiveJSON.Type, let value = primitive.init(json: raw) as? T {"
new_guard = "if let primitive = T.self as? any PrimitiveJSON.Type, let decoded = primitive.init(json: raw), let value = decoded as? T {"
assert method.count(old_guard) == 1
fixed_method = method.replace(old_guard, new_guard)
(parser_tests / "PrimitiveJSON.swift").write_text((persistence / "PrimitiveJSON.swift").read_text(encoding="utf-8"), encoding="utf-8")
support = '''import Foundation
enum RowCodec { static func isNull(_ data: Data) -> Bool { data.elementsEqual("null".utf8) } }
enum PortableDataError: Error { case undecodable(entity: String, key: String, underlying: String) }
'''
support += "enum OriginalParser { static let decoder = JSONDecoder()\n" + method + "\n}\n"
support += "enum FixedParser { static let decoder = JSONDecoder()\n" + fixed_method + "\n}\n"
(parser_tests / "Parsers.swift").write_text(support, encoding="utf-8")
(parser_tests / "main.swift").write_text(r'''import Foundation
let encoder = JSONEncoder()
let escaped = "Original alias: \"Example\""
let encoded = try encoder.encode(escaped)
let old: String? = try OriginalParser.decode(String?.self, from: encoded, entity: "Fixture", key: "note")
assert(old == nil, "The suspected optional-cast failure was not reproduced")
print("REPRODUCED: the original escaped optional string decodes as nil after storage")
for original in ["plain", escaped, "line1\nline2", "path\\folder", "中文 and emoji 🧪"] {
    let raw = try encoder.encode(original)
    let restored: String? = try FixedParser.decode(String?.self, from: raw, entity: "Fixture", key: "note")
    assert(restored == original)
    let required: String = try FixedParser.decode(String.self, from: raw, entity: "Fixture", key: "note")
    assert(required == original)
}
let none: String? = try FixedParser.decode(String?.self, from: Data("null".utf8), entity: "Fixture", key: "note")
assert(none == nil)
let unicode: String? = try FixedParser.decode(String?.self, from: Data(#""\u0041""#.utf8), entity: "Fixture", key: "note")
assert(unicode == "A")
do {
    let _: String? = try FixedParser.decode(String?.self, from: Data("123".utf8), entity: "Fixture", key: "note")
    assertionFailure("Wrongly typed data must throw instead of becoming nil")
} catch { }
print("FIX PASSED: optional and required strings preserve quotes, newlines, backslashes, Unicode and genuine null; wrong types throw")
''', encoding="utf-8")
