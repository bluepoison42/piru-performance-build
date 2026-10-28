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
text, builds = re.subn(r"CURRENT_PROJECT_VERSION = \d+;", "CURRENT_PROJECT_VERSION = 70009;", text)
assert versions and builds
project.write_text(text, encoding="utf-8")

manifest = root / "android/app/Android/app/src/main/AndroidManifest.xml"
text = manifest.read_text(encoding="utf-8")
assert 'android:label="${PRODUCT_NAME}"' in text
text = text.replace('android:label="${PRODUCT_NAME}"', 'android:label="Piru Perf Test"')
# The test app should not compete with the official app for normal Piru links.
text = re.sub(r"\s*<intent-filter\b[^>]*>.*?</intent-filter>", lambda match: "" if "android.intent.action.VIEW" in match.group() else match.group(), text, flags=re.S)
# Release stays non-debuggable; this only lets simpleperf/Perfetto sample it.
anchor = '        android:icon="@mipmap/ic_launcher">\n'
assert text.count(anchor) == 1
text = text.replace(anchor, anchor + '        <profileable android:shell="true" tools:targetApi="29" />\n')
manifest.write_text(text, encoding="utf-8")
assert 'android:allowBackup="false"' in text
assert 'android:authorities="${applicationId}.files"' in text

shortcuts = root / "android/app/Android/app/src/main/res/xml/shortcuts.xml"
if shortcuts.exists():
    shortcuts.write_text(shortcuts.read_text(encoding="utf-8").replace(old_id, new_id), encoding="utf-8")

builder = root / "android/tools/build-app.sh"
text = builder.read_text(encoding="utf-8")
assert "--package-path . --build-system native" in text
builder.write_text(text.replace("--package-path . --build-system native", "--package-path . --build-system native --jobs 4"), encoding="utf-8")
for relative in ("android/tools/setup.sh", "android/tools/build-app.sh", "android/tools/package-apk.sh"):
    path = root / relative
    text = path.read_text(encoding="utf-8")
    text = text.replace('export JAVA_HOME=$(/usr/libexec/java_home -v 21)', 'export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}"')
    text = text.replace('/usr/libexec/java_home -v 21 > /dev/null 2>&1 || missing+=', '[[ -x "${JAVA_HOME}/bin/java" ]] || missing+=')
    if relative == "android/tools/setup.sh":
        java_home = 'export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}"\n'
        assert text.count(java_home) == 1 and text.count("missing=()\n") == 1
        text = text.replace(java_home, "").replace("missing=()\n", java_home + "missing=()\n")
        assert text.index(java_home) < text.index('[[ -x "${JAVA_HOME}/bin/java" ]]')
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
    ("$0.dueDay >= today", "$0.dueDay == today"),
    ("return time <= Self.nowMinutes", "return Calendar.medicationClockMinutes(time) <= Calendar.medicationClockMinutes(Self.nowMinutes)"),
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
    ("        let day: Date\n", "        let day: Date\n        let boundary: Int\n"),
    ("            day: Calendar.current.medicationDayLabel(for: .now),", "            day: Calendar.current.medicationDayLabel(for: .now),\n            boundary: Calendar.sessionDayBoundaryHour,"),
])
patch("Piru/Views/Insights/AdherenceModel.swift", [
    ("AdherenceCalculator.adherence(for: .now,", "AdherenceCalculator.adherence(for: calendar.medicationDayLabel(for: .now),"),
    ("calendar.startOfDay(for: entry.timestamp)", "calendar.medicationDayLabel(for: entry.timestamp)"),
    ("$0.date <= .now", "$0.date <= calendar.medicationDayLabel(for: .now)"),
])

patch("Piru/Views/Insights/InsightsView.swift", [
    ("        var entriesByDay: [Date: [DoseEntry]] = [:]", "        var entriesByDay: [Date: [DoseEntry]] = [:]\n        var adherenceEntriesByDay: [Date: [DoseEntry]] = [:]"),
    ("            entriesByDay[cal.startOfDay(for: entry.timestamp), default: []].append(entry)", "            entriesByDay[cal.startOfDay(for: entry.timestamp), default: []].append(entry)\n            adherenceEntriesByDay[cal.medicationDayLabel(for: entry.timestamp), default: []].append(entry)"),
    ("computeMonthCells(cal: cal, entriesByDay: entriesByDay,", "computeMonthCells(cal: cal, entriesByDay: adherenceEntriesByDay,"),
    ("$0.date <= .now", "$0.date <= Calendar.current.medicationDayLabel(for: .now)"),
    ("Calendar.current.isDateInToday(cell.date)", "cell.date == Calendar.current.medicationDayLabel(for: .now)"),
    ("day.date > .now", "day.date > Calendar.current.medicationDayLabel(for: .now)"),
    ("from: .now)),", "from: cal.medicationDayLabel(for: .now))),"),
    ("Text(Date.now.formatted(.dateTime.month(.wide)))", "Text(Calendar.current.medicationDayLabel(for: .now).formatted(.dateTime.month(.wide)))"),
    ("        hasher.combine(DoseLogService.shared.revision)", "        hasher.combine(DoseLogService.shared.revision)\n        hasher.combine(Calendar.sessionDayBoundaryHour)\n        hasher.combine(calendar.medicationDayLabel(for: .now))"),
])
patch("Piru/Views/Insights/AdherenceView.swift", [
    ("@State private var displayedMonth: Date = .now", "@State private var displayedMonth: Date = Calendar.current.medicationDayLabel(for: .now)"),
    ("calendar.isDateInToday(date)", "date == calendar.medicationDayLabel(for: .now)"),
    ("date > .now", "date > calendar.medicationDayLabel(for: .now)"),
    ("equalTo: .now, toGranularity: .month", "equalTo: calendar.medicationDayLabel(for: .now), toGranularity: .month"),
    ("Text(Date.now.formatted(.dateTime.month(.wide)))", "Text(Calendar.current.medicationDayLabel(for: .now).formatted(.dateTime.month(.wide)))"),
    ("from: Date.now)", "from: calendar.medicationDayLabel(for: .now))"),
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
        guard !rows.isEmpty else { return 0 }
        let entriesByDay = Dictionary(grouping: try context.fetch(FetchDescriptor<DoseEntry>())) {
            calendar.medicationDayLabel(for: $0.timestamp)
        }
        var changed = 0
        for (day, occurrences) in Dictionary(grouping: rows, by: \\.dueDay) {
            let entries = entriesByDay[day] ?? []
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
anchor = "    static func commitImport(context: ModelContext) throws {\n"
assert text.count(anchor) == 1
text = text.replace(anchor, anchor + "        try RoutineOccurrenceService.repairHistoricalDays(in: context)\n")
importer.write_text(text, encoding="utf-8")

# Settings use the existing occurrence/notification pipeline and committed-log signal.
patch("Piru/Utilities/DoseNotificationManager.swift", [
    ("    static func syncMedReminders(in context: ModelContext) {", '''    static func medicationDayBoundaryChanged(in context: ModelContext) throws {
        UserDefaults.standard.removeObject(forKey: "piru.medicationHistoryBoundary.v2")
        try RoutineOccurrenceService.repairHistoricalDays(in: context)
        try context.save()
        DoseLogService.shared.changed()
        syncMedReminders(in: context)
        UserDefaults.standard.set(Calendar.sessionDayBoundaryHour, forKey: "piru.medicationHistoryBoundary.v2")
    }

    static func syncMedReminders(in context: ModelContext) {'''),
])
patch("Piru/Views/Settings/JournalSettingsView.swift", [
    ("import SwiftUI", "import SwiftData\nimport SwiftUI"),
    ("struct JournalSettingsView: View {", "struct JournalSettingsView: View {\n    @Environment(\\.modelContext) private var modelContext"),
    ("        .inlineNavigationTitle()", '''        .inlineNavigationTitle()
        .onChange(of: dayBoundaryHour) {
            do {
                try DoseNotificationManager.medicationDayBoundaryChanged(in: modelContext)
            } catch {
                print("Piru: medication-day history repair failed; will retry next launch.")
            }
        }'''),
])
patch("Piru/Views/Journal/DailyDose/MyMedsModel.swift", [
    ("        hasher.combine(DoseLogService.shared.revision)", "        hasher.combine(DoseLogService.shared.revision)\n        hasher.combine(Calendar.sessionDayBoundaryHour)\n        hasher.combine(Calendar.current.medicationDayLabel(for: .now))"),
])

launch = root / "android/app/Sources/Piru/Android/PiruAndroidApp.swift"
text = launch.read_text(encoding="utf-8")
anchor = "            await AppLaunch.finishLaunching(container: container)"
assert text.count(anchor) == 1
text = text.replace(anchor, anchor + '''
            let historyKey = "piru.medicationHistoryBoundary.v2"
            let boundary = Calendar.sessionDayBoundaryHour
            if UserDefaults.standard.object(forKey: historyKey) as? Int != boundary {
                do {
                    _ = try await RoutineOccurrenceService.repairHistoricalDays(container: container)
                    UserDefaults.standard.set(boundary, forKey: historyKey)
                    DoseLogService.shared.changed()
                    DoseNotificationManager.syncMedReminders(in: container.mainContext)
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
    assert text.count(anchor) == 1, anchor
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

# Unwrap failure before casting to an Optional, so escaped strings reach JSONDecoder.
snapshot_file = persistence / "Snapshot.swift"
snapshot_text = snapshot_file.read_text(encoding="utf-8")
assert snapshot_text.count(old_guard) == 1
snapshot_file.write_text(snapshot_text.replace(old_guard, new_guard), encoding="utf-8")

# A Query wrapper can be recreated when its parent tab recomposes. Share an
# unchanged unfiltered sort in the context, where all model mutations are seen.
entity_file = persistence / "EntityDescription.swift"
entity_text = entity_file.read_text(encoding="utf-8")
anchor = "    public var tracksMutations = true"
assert entity_text.count(anchor) == 1
entity_text = entity_text.replace(anchor, anchor + "\n    private(set) var attributePaths: Set<AnyKeyPath> = []")
old_property = "    public func property(_: String, _: KeyPath<some Any, some Any>, deleteRule _: Schema.Relationship.DeleteRule) {}"
assert entity_text.count(old_property) == 1
entity_text = entity_text.replace(old_property, '''    public func property(_: String, _ path: KeyPath<some Any, some Any>, deleteRule _: Schema.Relationship.DeleteRule) {
        attributePaths.insert(path)
    }''')
entity_file.write_text(entity_text, encoding="utf-8")

context_file = persistence / "ModelContext.swift"
context_text = context_file.read_text(encoding="utf-8")
query_tests = root / "ci/perf/query-tests"
query_tests.mkdir(parents=True, exist_ok=True)
(query_tests / "ModelContext-original.swift").write_text(context_text, encoding="utf-8")
(query_tests / "prepare_host.py").write_text('''from pathlib import Path
p = Path("android/Compat/Package.swift")
s = p.read_text()
begin = s.index('        .macro(\\n            name: "FoundationMacros"')
end = s.index('        .macro(\\n            name: "PortableDataMacros"', begin)
block = s[begin:end].replace('name: "FoundationMacros"', 'name: "PortableFoundationMacros"')
block = block.replace('            exclude: ["VENDORED.md"],', '            path: "Sources/FoundationMacros",\\n            exclude: ["VENDORED.md"],')
assert 'path: "Sources/FoundationMacros"' in block
s = s[:begin] + block + s[end:]
s = s.replace('.target(name: "FoundationMacros", condition:', '.target(name: "PortableFoundationMacros", condition:')
s = s.replace('"602.0.0" ..< "605.0.0"', 'exact: "602.0.0"')
p.write_text(s)
print("Host-only macro renamed to avoid shadowing Apple Foundation; production SwiftSyntax602 pin selected")
''', encoding="utf-8")
anchor = "    private var revision = 0"
assert context_text.count(anchor) == 1
context_text = context_text.replace(anchor, '''    private var revision = 0 {
        didSet { sortedReads.removeAll(keepingCapacity: true) }
    }
    // Keep ascending, descending and unsorted reads from evicting each other
    // between tabs. Only stored attributes qualify; computed keys may change.
    private var sortedReads: [String: [(revision: Int, order: Any, result: Any)]] = [:]''')
old_read = '''        var results = models(T._$entityName).compactMap { $0 as? T }
        if let predicate = descriptor.predicate {
            results = try results.filter { try predicate.evaluate($0) }
        }
        if !descriptor.sortBy.isEmpty {
            results.sort(using: descriptor.sortBy)
        }'''
assert context_text.count(old_read) == 1
context_text = context_text.replace(old_read, '''        let entity = T._$entityName
        let attributes = EntityDescription.of(T.self).attributePaths
        let cacheable = descriptor.predicate == nil && reportsEveryWrite && descriptor.sortBy.allSatisfy {
            $0.keyPath.map { attributes.contains($0) } ?? false
        }
        var results: [T]
        if cacheable, let cached = sortedReads[entity]?.first(where: {
            $0.revision == revision && ($0.order as? [SortDescriptor<T>]) == descriptor.sortBy
        }),
           let rows = cached.result as? [T] {
            results = rows
        } else {
            results = models(entity).compactMap { $0 as? T }
            if let predicate = descriptor.predicate {
                results = try results.filter { try predicate.evaluate($0) }
            }
            if !descriptor.sortBy.isEmpty {
                results.sort(using: descriptor.sortBy)
            }
            if cacheable {
                var plans = sortedReads[entity] ?? []
                plans.append((revision, descriptor.sortBy, results))
                sortedReads[entity] = Array(plans.suffix(3))
            }
        }''')
context_file.write_text(context_text, encoding="utf-8")

(root / "android/Compat/Tests/PortableDataTests/QueryResultCacheTests.swift").write_text(r'''import Foundation
import Synchronization
import PortableData
import Testing

private enum QuerySortProbe {
    static let comparisons = Mutex(0)
    static let direction = Mutex(1)
    static func reset() { comparisons.withLock { $0 = 0 } }
    static var count: Int { comparisons.withLock { $0 } }
}

private struct CountedRank: Codable, Comparable, Sendable {
    var value: Int
    static func < (lhs: Self, rhs: Self) -> Bool {
        QuerySortProbe.comparisons.withLock { $0 += 1 }
        return lhs.value < rhs.value
    }
}

@Model
private final class QueryCacheRow {
    var id: UUID = UUID()
    var rank: CountedRank
    var notes: String?
    var computedRank: CountedRank {
        CountedRank(value: rank.value * QuerySortProbe.direction.withLock { $0 })
    }
    init(_ rank: Int) { self.rank = CountedRank(value: rank); notes = "alias: \"fixture\"" }
}

@Model
private final class UntrackedQueryCacheRow {
    var id: UUID = UUID()
    var rank: CountedRank { didSet {} }
    init(_ rank: Int) { self.rank = CountedRank(value: rank) }
}

// Observation's onChange is Sendable but executes synchronously on the writing thread.
private final class ReentrantQueryProbe: @unchecked Sendable {
    let context: ModelContext
    var values: [Int]?
    init(_ context: ModelContext) { self.context = context }
    func fetch() {
        values = try? context.fetch(FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank)])).map(\.rank.value)
    }
}

@Suite(.serialized)
struct QueryResultCacheTests {
    private func fixture(_ count: Int = 8) throws -> (ModelContainer, ModelContext, [QueryCacheRow]) {
        let url = FileManager.default.temporaryDirectory.appending(path: "query-cache-\(UUID()).sqlite")
        let container = try ModelContainer(for: QueryCacheRow.self, configurations: ModelConfiguration(url: url))
        let context = ModelContext(container)
        let rows = (0..<count).reversed().map { QueryCacheRow($0) }
        rows.forEach { context.insert($0) }
        try context.save()
        return (container, context, rows)
    }

    @Test func repeatedRequestsReuseAnUnchangedSort() throws {
        let (_, context, _) = try fixture(1794)
        _ = try context.fetch(FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank)]))
        QuerySortProbe.reset()
        for _ in 0..<5 {
            let rows = try context.fetch(FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank)]))
            #expect(rows.first?.rank.value == 0)
            #expect(rows.last?.rank.value == 1793)
        }
        #expect(QuerySortProbe.count == 0, "Repeated fetch unexpectedly sorted unchanged rows")
    }

    @Test func orderAndPagingAreIndependent() throws {
        let (_, context, _) = try fixture()
        _ = try context.fetch(FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank)]))
        var page = FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank)])
        page.fetchOffset = 2; page.fetchLimit = 3
        QuerySortProbe.reset()
        #expect(try context.fetch(page).map(\.rank.value) == [2,3,4])
        #expect(QuerySortProbe.count == 0)
        let reverse = FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank, order: .reverse)])
        #expect(try context.fetch(reverse).map(\.rank.value) == Array((0..<8).reversed()))
        #expect(QuerySortProbe.count > 0)
        _ = try context.fetch(FetchDescriptor<QueryCacheRow>())
        QuerySortProbe.reset()
        #expect(try context.fetch(page).map(\.rank.value) == [2,3,4])
        #expect(try context.fetch(reverse).first?.rank.value == 7)
        #expect(QuerySortProbe.count == 0, "Chronological and unsorted tab queries evicted each other")
    }

    @Test func mutationsInsertionsDeletionsAndRollbackRefreshTheSort() throws {
        let (_, context, rows) = try fixture()
        let query = FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank)])
        _ = try context.fetch(query)
        rows[0].rank = CountedRank(value: -1)
        #expect(try context.fetch(query).first === rows[0])
        context.rollback()
        #expect(try context.fetch(query).first?.rank.value == 0)
        let added = QueryCacheRow(-2)
        context.insert(added)
        #expect(try context.fetch(query).first === added)
        context.delete(added)
        #expect(try context.fetch(query).count == 8)
        #expect(try context.fetch(query).first?.notes == "alias: \"fixture\"")
    }

    @Test func synchronousWillSetFetchCannotCacheThePreAssignmentOrder() throws {
        let (_, context, rows) = try fixture(2)
        let query = FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank)])
        #expect(!context.autosaveEnabled)
        #expect(try context.fetch(query).map(\.rank.value) == [0, 1])
        let probe = ReentrantQueryProbe(context)
        withObservationTracking {
            _ = rows[0].rank
        } onChange: {
            probe.fetch()
        }
        rows[0].rank = CountedRank(value: -1)
        #expect(probe.values == [0, 1], "The synchronous observer must see the old values")
        #expect(try context.fetch(query).map(\.rank.value) == [-1, 0])
        QuerySortProbe.reset()
        #expect(try context.fetch(query).first === rows[0])
        #expect(QuerySortProbe.count == 0, "The corrected order should still be cached")
    }

    @Test func otherContainersSavesAreVisible() throws {
        let (container, context, _) = try fixture()
        let query = FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank)])
        _ = try context.fetch(query)
        let other = try ModelContext(ModelContainer(for: Schema([QueryCacheRow.self]), configurations: container.configurations))
        let row = try #require(other.fetch(query).last)
        row.rank = CountedRank(value: -3)
        try other.save()
        #expect(try context.fetch(query).first?.id == row.id)
        #expect(try context.fetch(query).first?.rank.value == -3)
    }

    @Test func predicatesNeverReuseAnUnfilteredResult() throws {
        let (_, context, _) = try fixture()
        _ = try context.fetch(FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.rank)]))
        let filter = FetchDescriptor<QueryCacheRow>(predicate: #Predicate { $0.rank.value >= 4 }, sortBy: [SortDescriptor(\.rank)])
        #expect(try context.fetch(filter).map(\.rank.value) == [4,5,6,7])
        QuerySortProbe.reset()
        #expect(try context.fetch(filter).count == 4)
        #expect(QuerySortProbe.count > 0)
    }

    @Test func computedSortKeysAreNotCached() throws {
        let (_, context, _) = try fixture()
        let query = FetchDescriptor<QueryCacheRow>(sortBy: [SortDescriptor(\.computedRank)])
        #expect(try context.fetch(query).first?.rank.value == 0)
        QuerySortProbe.direction.withLock { $0 = -1 }
        defer { QuerySortProbe.direction.withLock { $0 = 1 } }
        #expect(try context.fetch(query).first?.rank.value == 7)
    }

    @Test func unreportedWritesAreNotCached() throws {
        let container = try ModelContainer(for: UntrackedQueryCacheRow.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let a = UntrackedQueryCacheRow(0), b = UntrackedQueryCacheRow(1)
        context.insert(a); context.insert(b)
        let query = FetchDescriptor<UntrackedQueryCacheRow>(sortBy: [SortDescriptor(\.rank)])
        #expect(context.currentRevision() == nil)
        #expect(try context.fetch(query).first === a)
        b.rank = CountedRank(value: -1)
        #expect(try context.fetch(query).first === b)
    }
}
''', encoding="utf-8")

# A main-thread read of a model a view has shown also goes to Skip's registrar,
# a JNI call into Compose state. The 70002 profile spent ~25% of the main thread
# there, under SortDescriptor.compare: a fetch's sort reads each row's keys
# O(n log n) times. PortableData's own passes need no such subscription; views
# refresh on the context's change handler and DoseLogService's revision, and
# rows without a bridge were already read without one. Writes still report.
observation_file = persistence / "Observation.swift"
observation_text = observation_file.read_text(encoding="utf-8")
anchor = "    public func didSet<Subject: Observable>(_ subject: Subject, keyPath: KeyPath<Subject, some Any>) {\n"
assert observation_text.count(anchor) == 1
observation_text = observation_text.replace(anchor, anchor + '''        if let model = subject as? any PersistentModel {
            // Discard reads made by synchronous willSet observers, after the assignment.
            model._$backing.context?.noteMutation(of: model)
        }
''')
old_access = "        slot.bridge(making: true)?.access(subject, keyPath: keyPath)\n"
assert observation_text.count(old_access) == 1
observation_text = observation_text.replace(old_access, "        slot.reader()?.access(subject, keyPath: keyPath)\n")
anchor = "    private var made: (any ModelObservationBridge)?\n"
assert observation_text.count(anchor) == 1
observation_text = observation_text.replace(anchor, anchor + '''
    /// The bridge a main-thread read reports to; none during PortableData's own passes,
    /// whose reads a view does not depend on.
    func reader() -> (any ModelObservationBridge)? {
        guard isMainThread(), ModelObservation.makesBridges else { return nil }
        return bridge(making: true)
    }
''')
observation_file.write_text(observation_text, encoding="utf-8")

bridge_tests = root / "android/Compat/Tests/PiruModelTests/BridgeTests.swift"
bridge_text = bridge_tests.read_text(encoding="utf-8")
anchor = "\n}\n\nprivate struct PassFailed: Error {}\n"
assert bridge_text.count(anchor) == 1
bridge_text = bridge_text.replace(anchor, '''

    @Test
    func `A fetch's filter and sort report no reads to bridges views made, and writes still reach them`() throws {
        let store = TestStore()
        try seedJournal(store)
        let context = try ModelContext(store.container())
        let bridges = BridgeLog()
        ModelObservation.makeBridge = { CountingBridge(log: bridges) }
        defer { ModelObservation.makeBridge = nil }

        for dose in try context.doses() {
            _ = dose.substance
        }
        #expect(bridges.made == 3)
        let shown = bridges.calls

        let floor = origin.addingTimeInterval(-1)
        let sorted = try context.fetch(FetchDescriptor<DoseEntry>(
            predicate: #Predicate { $0.timestamp > floor },
            sortBy: [SortDescriptor(\\.substance, order: .reverse), SortDescriptor(\\.timestamp)],
        ))
        #expect(bridges.calls == shown, "A fetch's own reads reached the renderer's bridge")
        #expect(sorted.first?.substance == "caffeine2")
        #expect(bridges.calls == shown + 1)
        sorted[0].amount = 7
        #expect(bridges.writes(to: \\DoseEntry.amount) == 1)
        #expect(bridges.made == 3)
    }
}

private struct PassFailed: Error {}
''')
bridge_tests.write_text(bridge_text, encoding="utf-8")
(query_tests / "Observation-original.swift").write_text(
    (persistence / "Observation.swift").read_text(encoding="utf-8").replace(
        "        slot.reader()?.access(subject, keyPath: keyPath)\n", old_access), encoding="utf-8")
print("Prepared bridge-free traversal reads: sorts and filters make no JNI call per key read")

# Cold-start A/B controls exist only in this isolated performance variant.
shadow_patch = root / "android/vendor/skip-ui/0018-perftest-shadow-downsampling.patch"
assert not shadow_patch.exists(), "The performance shadow patch already exists"
shadow_patch.write_text(r'''The performance variant needs cold-start shadow A/B switches and activity content-capture controls; downsample only the recorded shadow while preserving patch 0006 single composition and padded blur bounds.

diff --git a/Sources/SkipUI/Skip/Shadowed.kt b/Sources/SkipUI/Skip/Shadowed.kt
--- a/Sources/SkipUI/Skip/Shadowed.kt
+++ b/Sources/SkipUI/Skip/Shadowed.kt
@@ -5,11 +5,14 @@
 import android.os.Build
 import androidx.compose.runtime.Composable
 import androidx.compose.ui.draw.drawWithContent
+import androidx.compose.ui.geometry.Offset
 import androidx.compose.ui.graphics.BlurEffect
 import androidx.compose.ui.graphics.Color
 import androidx.compose.ui.graphics.ColorFilter
 import androidx.compose.ui.graphics.ColorMatrix
 import androidx.compose.ui.graphics.TileMode
+import androidx.compose.ui.graphics.drawscope.clipRect
+import androidx.compose.ui.graphics.drawscope.scale
 import androidx.compose.ui.graphics.drawscope.translate
 import androidx.compose.ui.graphics.layer.drawLayer
 import androidx.compose.ui.graphics.rememberGraphicsLayer
@@ -18,7 +21,14 @@
 import androidx.compose.ui.unit.Dp
 import androidx.compose.ui.unit.IntOffset
 import androidx.compose.ui.unit.IntSize
+import kotlin.jvm.JvmStatic
 import kotlin.math.ceil
+
+// Added only by the performance variant's vendor patch; read before the first composition.
+object PiruPerfFlags {
+    @JvmStatic var shadowMode: Int = 2
+    var contentCapture: Boolean = false
+}
 
 /// Compose the given content with a drop shadow on all non-transparent pixels.
 ///
@@ -26,28 +36,61 @@
 /// recording through the shadow color and blur. Composing the content a second time for the shadow
 /// would give every control inside a live twin, with its own state and its own focus target.
 @Composable fun Shadowed(context: ComposeContext, color: Color, offsetX: Dp, offsetY: Dp, blurRadius: Dp, content: @Composable (ComposeContext) -> Unit) {
-    val density = LocalDensity.current
-    val offsetXPx = with(density) { offsetX.toPx() }.toInt()
-    val offsetYPx = with(density) { offsetY.toPx() }.toInt()
-    val blurRadiusPx = with(density) { blurRadius.toPx() }
-    val paddingPx = ceil(blurRadiusPx).toInt()
-    val contentLayer = rememberGraphicsLayer()
-    val shadowLayer = rememberGraphicsLayer()
+    // Keep the same single Layout/content tree even when measuring the no-shadow ceiling.
+    val modifier = if (PiruPerfFlags.shadowMode == 1) {
+        context.modifier
+    } else {
+        val density = LocalDensity.current
+        val offsetXPx = with(density) { offsetX.toPx() }.toInt()
+        val offsetYPx = with(density) { offsetY.toPx() }.toInt()
+        val blurRadiusPx = with(density) { blurRadius.toPx() }
+        val paddingPx = ceil(blurRadiusPx).toInt()
+        val hasBlur = blurRadiusPx > 0f && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
+        // Never downsample a sharp fallback, and keep small blurs from becoming pixelated.
+        val sampleScale = if (PiruPerfFlags.shadowMode != 2 || !hasBlur || blurRadiusPx < 2f) {
+            1f
+        } else if (blurRadiusPx < 8f) {
+            2f
+        } else {
+            4f
+        }
+        val contentLayer = rememberGraphicsLayer()
+        val shadowLayer = rememberGraphicsLayer()
 
-    val modifier = context.modifier.drawWithContent {
-        contentLayer.record { this@drawWithContent.drawContent() }
-        // Padded by the blur radius so the blur is not clipped at the content's edges.
-        shadowLayer.record(size = IntSize(size.width.toInt() + paddingPx * 2, size.height.toInt() + paddingPx * 2)) {
-            translate(left = paddingPx.toFloat(), top = paddingPx.toFloat()) {
-                drawLayer(contentLayer)
+        context.modifier.drawWithContent {
+            contentLayer.record { this@drawWithContent.drawContent() }
+            val paddedWidth = size.width.toInt() + paddingPx * 2
+            val paddedHeight = size.height.toInt() + paddingPx * 2
+            // Low-resolution bounds cover the same padded content, rounding outward only.
+            val shadowSize = IntSize(
+                ceil(paddedWidth / sampleScale).toInt(),
+                ceil(paddedHeight / sampleScale).toInt()
+            )
+            shadowLayer.record(size = shadowSize) {
+                // A source point x records at (x + paddingPx) / s (likewise for y).
+                scale(scale = 1f / sampleScale, pivot = Offset.Zero) {
+                    // Match mode 0's input bounds, including overflow from the content layer.
+                    clipRect(right = paddedWidth.toFloat(), bottom = paddedHeight.toFloat()) {
+                        translate(left = paddingPx.toFloat(), top = paddingPx.toFloat()) {
+                            drawLayer(contentLayer)
+                        }
+                    }
+                }
             }
+            shadowLayer.colorFilter = ColorFilter.colorMatrix(shadowColorMatrix(color))
+            // RenderEffect runs in the small layer's local pixels, before its scale transform.
+            val sampledRadius = blurRadiusPx / sampleScale
+            shadowLayer.renderEffect = if (hasBlur) BlurEffect(sampledRadius, sampledRadius, TileMode.Decal) else null
+            // Use the local top-left as pivot, not the default layer center:
+            // (offset - padding) + s * ((x + padding) / s) = x + offset.
+            shadowLayer.pivotOffset = Offset.Zero
+            shadowLayer.scaleX = sampleScale
+            shadowLayer.scaleY = sampleScale
+            shadowLayer.topLeft = IntOffset(offsetXPx - paddingPx, offsetYPx - paddingPx)
+            // Like mode 0, let the filtered result extend beyond the layer's input bounds.
+            drawLayer(shadowLayer)
+            drawLayer(contentLayer)
         }
-        shadowLayer.colorFilter = ColorFilter.colorMatrix(shadowColorMatrix(color))
-        // RenderEffect blur needs API 31; below it the shadow is drawn sharp.
-        shadowLayer.renderEffect = if (blurRadiusPx > 0f && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) BlurEffect(blurRadiusPx, blurRadiusPx, TileMode.Decal) else null
-        shadowLayer.topLeft = IntOffset(offsetXPx - paddingPx, offsetYPx - paddingPx)
-        drawLayer(shadowLayer)
-        drawLayer(contentLayer)
     }
 
     Layout(modifier = modifier, content = {
''', encoding="utf-8")

activity = root / "android/app/Android/app/src/main/kotlin/Main.kt"
text = activity.read_text(encoding="utf-8")
anchor = "    override fun onCreate(savedInstanceState: android.os.Bundle?) {\n"
assert text.count(anchor) == 1
text = text.replace(anchor, "    @OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)\n" + anchor)
anchor = '        logger.info("starting activity")\n'
assert text.count(anchor) == 1
text = text.replace(anchor, '''        if (intent.hasExtra("piru_shadow_mode")) {
            skip.ui.PiruPerfFlags.shadowMode = intent.getIntExtra("piru_shadow_mode", skip.ui.PiruPerfFlags.shadowMode)
        }
        if (intent.hasExtra("piru_content_capture")) {
            skip.ui.PiruPerfFlags.contentCapture = intent.getBooleanExtra("piru_content_capture", skip.ui.PiruPerfFlags.contentCapture)
        }
        // The platform opt-out alone need not remove Compose's existing capture session.
        androidx.compose.ui.contentcapture.ContentCaptureManager.isEnabled = skip.ui.PiruPerfFlags.contentCapture
        if (!skip.ui.PiruPerfFlags.contentCapture && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            getSystemService(android.view.contentcapture.ContentCaptureManager::class.java)?.setContentCaptureEnabled(false)
        }
''' + anchor)
activity.write_text(text, encoding="utf-8")
print("Prepared 70008: shadow modes 0/1/2 (default 2), platform and Compose content capture off by default")

# 70008 regression fixtures below extract production members; no second matching algorithm.
model_tests = root / "android/Compat/Tests/PiruModelTests"
staged = model_tests / "staged-sources.txt"
staged_text = staged.read_text(encoding="utf-8")
for relative in ("Shared/CalendarSessionDay.swift", "Shared/MedSchedule.swift"):
    assert relative not in staged_text
    staged_text += "\n" + relative + "\n"
staged.write_text(staged_text, encoding="utf-8")

service_text = service.read_text(encoding="utf-8")
# The host suite tests the synchronous database path; it has no DatabaseActor executor.
for anchor in ("static func needsReconcile(", "static func repairHistoricalDays(container:"):
    member = "    @DatabaseActor\n    " + swift_member(service_text, anchor)
    assert service_text.count(member) == 1
    service_text = service_text.replace(member, "")
service_text = service_text.replace("import SwiftData", "import PortableData")
calculator_text = (root / "Piru/Utilities/AdherenceCalculator.swift").read_text(encoding="utf-8")
is_due = swift_member(calculator_text, "nonisolated static func isDue(startDate:")
commit = swift_member(importer.read_text(encoding="utf-8"), "static func commitImport(context:")
notification_text = (root / "Piru/Utilities/DoseNotificationManager.swift").read_text(encoding="utf-8")
boundary_changed = swift_member(notification_text, "static func medicationDayBoundaryChanged(")
sync_reminders = swift_member(notification_text, "static func syncMedReminders(in context:")
card_text = (root / "Piru/Views/Journal/DailyDose/MyMedsCard.swift").read_text(encoding="utf-8")
today_occurrences = swift_member(card_text, "private var todayOccurrences:").replace("private var", "var", 1)
streak_key = swift_member((root / "Piru/Utilities/AdherenceStreakStore.swift").read_text(encoding="utf-8"), "private struct Key:").replace("private struct Key", "struct MedicationStreakKey", 1)
insights_text = (root / "Piru/Views/Insights/InsightsView.swift").read_text(encoding="utf-8")
bucket_start = "        let cal = calendar\n"
bucket_end = "        let cells = computeMonthCells("
assert insights_text.count(bucket_start) == insights_text.count(bucket_end) == 1
insights_buckets = insights_text[insights_text.index(bucket_start):insights_text.index(bucket_end)]
due_now = swift_member(card_text, "var isDueNow:")

support = '''import Foundation
import PortableData

nonisolated enum AppIdentity { static let appGroup = "piru.ci.medication-tests" }
// StageSources rewrites the App Group suite to this Android accessor (Foundation+Android.swift).
extension UserDefaults {
    nonisolated static var androidAppGroup: UserDefaults? { UserDefaults(suiteName: AppIdentity.appGroup) }
}
enum AdherenceCalculator {
''' + is_due + "\n}\n" + service_text + '''
// Only OS/UI side effects are doubles. Reconcile, history matching, commit order and
// calendar logic above are the production members over the actual PortableData models.
@MainActor final class DoseLogService {
    static let shared = DoseLogService()
    var revision = 0
    func changed() { revision += 1 }
}
@MainActor final class WidgetCenter {
    static let shared = WidgetCenter()
    func reloadAllTimelines() {}
}
@MainActor enum DataExportImport {
''' + commit + '''
}
@MainActor enum DoseNotificationManager {
    static var reminderSyncs = 0
    private static func scheduleMedReminders(in context: ModelContext) { reminderSyncs += 1 }
''' + boundary_changed + "\n" + sync_reminders + '''
}
struct MedicationCardFixture {
    var recentOccurrences: [RoutineOccurrence]
''' + today_occurrences + "\n}\n" + streak_key + '''
struct InsightsBucketsFixture {
    let calendar = Calendar.current
    func group(_ entries: [DoseEntry]) -> (usage: [Date: [DoseEntry]], adherence: [Date: [DoseEntry]]) {
''' + insights_buckets + '''
        return (entriesByDay, adherenceEntriesByDay)
    }
}
struct DueSlotFixture {
    enum State { case pending, taken, skipped }
    let state: State
    let time: Int?
    // Controlled clock input to the unmodified production comparison.
    static var nowMinutes = 0
''' + due_now + "\n}\n"
(model_tests / "MedicationDayProduction.swift").write_text(support, encoding="utf-8")
(model_tests / "MedicationDayTests.swift").write_text(r'''import Foundation
import PortableData
import Testing

@MainActor
@Suite(.serialized)
struct MedicationDayTests {
    private func withBoundary(_ body: (UserDefaults) throws -> Void) rethrows {
        let defaults = UserDefaults(suiteName: AppIdentity.appGroup)!
        let key = Calendar.dayBoundaryHourKey
        let original = defaults.object(forKey: key)
        let historyKey = "piru.medicationHistoryBoundary.v2"
        let originalHistory = UserDefaults.standard.object(forKey: historyKey)
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
            if let originalHistory { UserDefaults.standard.set(originalHistory, forKey: historyKey) }
            else { UserDefaults.standard.removeObject(forKey: historyKey) }
        }
        defaults.set(4, forKey: key)
        try body(defaults)
    }

    @Test func historyRegroupsExistingRowsAndPreservesEveryDose() throws {
        try withBoundary { defaults in
            let calendar = Calendar.current
            let today = calendar.medicationDayLabel(for: .now)
            let first = calendar.date(byAdding: .day, value: -3, to: today)!
            let second = calendar.date(byAdding: .day, value: 1, to: first)!
            let early = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: second)!
            let store = TestStore()
            let context = try ModelContext(store.container())
            let dose = DoseEntry(substance: "test-med", amount: 1.25, unit: "mg", route: .oral, timestamp: early)
            let a = RoutineOccurrence(substance: "test-med", route: .oral, dueDay: first)
            let b = RoutineOccurrence(substance: "test-med", route: .oral, dueDay: second)
            let skipped = RoutineOccurrence(substance: "user-skip", route: .oral, dueDay: first)
            let future = RoutineOccurrence(substance: "test-med", route: .oral,
                dueDay: calendar.date(byAdding: .day, value: 1, to: today)!)
            a.state = .missed; b.state = .missed; skipped.state = .skipped
            context.insert(dose)
            for row in [a, b, skipped, future] { context.insert(row) }
            try context.save()
            let originalDoses = try JSONSerialization.data(withJSONObject: store.rows("DoseEntry"), options: .sortedKeys)
            let occurrenceIDs = Set(try context.fetch(FetchDescriptor<RoutineOccurrence>()).map(\.persistentModelID))
            #expect(try RoutineOccurrenceService.repairHistoricalDays(in: context) == 1)
            #expect(a.state == .logged && a.satisfyingEntryID == dose.id)
            #expect(b.state == .missed)
            #expect(try RoutineOccurrenceService.repairHistoricalDays(in: context) == 0)
            defaults.set(0, forKey: Calendar.dayBoundaryHourKey)
            #expect(try RoutineOccurrenceService.repairHistoricalDays(in: context) == 2)
            #expect(a.state == .missed && a.satisfyingEntryID == nil)
            #expect(b.state == .logged && b.satisfyingEntryID == dose.id)
            #expect(skipped.state == .skipped && future.state == .pending)
            try context.save()
            #expect(try JSONSerialization.data(withJSONObject: store.rows("DoseEntry"), options: .sortedKeys) == originalDoses)
            #expect(Set(try context.fetch(FetchDescriptor<RoutineOccurrence>()).map(\.persistentModelID)) == occurrenceIDs)
        }
    }

    @Test func commonImportCommitRepairsHistoryWithoutSettings() throws {
        try withBoundary { _ in
            let calendar = Calendar.current
            let today = calendar.medicationDayLabel(for: .now)
            let day = calendar.date(byAdding: .day, value: -2, to: today)!
            let store = TestStore()
            let container = try store.container()
            let context = ModelContext(container)
            let missed = RoutineOccurrence(substance: "imported-med", route: .oral, dueDay: day)
            missed.state = .missed
            context.insert(missed)
            try context.save()
            let dose = DoseEntry(substance: "imported-med", amount: 2, unit: "mg", route: .oral,
                timestamp: calendar.medicationDayMoment(minutes: 120, onLabel: day)!)
            context.insert(dose)
            let revision = DoseLogService.shared.revision
            try DataExportImport.commitImport(context: context)
            #expect(DoseLogService.shared.revision == revision + 1)
            let reopened = ModelContext(container)
            let stored = try #require(reopened.fetch(FetchDescriptor<RoutineOccurrence>()).first)
            #expect(stored.state == .logged && stored.satisfyingEntryID == dose.id)
            #expect(try reopened.fetchCount(FetchDescriptor<DoseEntry>()) == 1)
            #expect(try RoutineOccurrenceService.repairHistoricalDays(in: context) == 0)
        }
    }

    @Test func boundaryChangeReconcilesTodaySignalsAndReschedulesEvenWithoutHistory() throws {
        try withBoundary { defaults in
            let store = TestStore()
            let context = try ModelContext(store.container())
            let item = DailyDoseItem(substance: "today-med", amount: 1, unit: "mg", route: .oral)
            item.startDate = Calendar.current.date(byAdding: .day, value: -2, to: .now)!
            context.insert(item)
            try context.save()
            let revision = DoseLogService.shared.revision
            let syncs = DoseNotificationManager.reminderSyncs
            defaults.set(0, forKey: Calendar.dayBoundaryHourKey)
            try DoseNotificationManager.medicationDayBoundaryChanged(in: context)
            #expect(DoseLogService.shared.revision == revision + 1)
            #expect(DoseNotificationManager.reminderSyncs == syncs + 1)
            let rows = try context.fetch(FetchDescriptor<RoutineOccurrence>())
            #expect(rows.count == 1)
            #expect(rows.first?.dueDay == Calendar.current.medicationDayLabel(for: .now))
            #expect(try context.fetchCount(FetchDescriptor<DoseEntry>()) == 0)
            let day = Calendar.current.startOfDay(for: .now)
            #expect(MedicationStreakKey(revision: 1, schedule: 1, day: day, boundary: 4)
                != MedicationStreakKey(revision: 1, schedule: 1, day: day, boundary: 0))
        }
    }

    @Test func todayOccurrencesExcludeBothAdjacentDays() throws {
        try withBoundary { _ in
            let calendar = Calendar.current
            let today = calendar.medicationDayLabel(for: .now)
            let yesterday = RoutineOccurrence(substance: "same-med", route: .oral,
                dueDay: calendar.date(byAdding: .day, value: -1, to: today)!)
            let current = RoutineOccurrence(substance: "same-med", route: .oral, dueDay: today)
            current.state = .logged
            let tomorrow = RoutineOccurrence(substance: "same-med", route: .oral,
                dueDay: calendar.date(byAdding: .day, value: 1, to: today)!)
            let rows = MedicationCardFixture(recentOccurrences: [yesterday, current, tomorrow]).todayOccurrences
            #expect(rows.count == 1 && rows.first === current)
        }
    }

    @Test func insightsKeepsNaturalUsageAndMedicationAdherenceBucketsSeparate() throws {
        try withBoundary { _ in
            let calendar = Calendar.current
            let day = calendar.date(from: DateComponents(year: 2026, month: 5, day: 21))!
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let evening = DoseEntry(substance: "test", amount: 1,
                timestamp: calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day)!)
            let overnight = DoseEntry(substance: "test", amount: 1,
                timestamp: calendar.date(bySettingHour: 2, minute: 0, second: 0, of: next)!)
            let buckets = InsightsBucketsFixture().group([evening, overnight])
            #expect(buckets.usage[day]?.count == 1 && buckets.usage[next]?.count == 1)
            #expect(buckets.adherence[day]?.count == 2 && buckets.adherence[next] == nil)
        }
    }

    @Test func myMedsDueOrderWrapsAtBoundaryWithoutChangingDisplayedMinutes() throws {
        try withBoundary { _ in
            let overnight = DueSlotFixture(state: .pending, time: 120)
            let evening = DueSlotFixture(state: .pending, time: 1380)
            DueSlotFixture.nowMinutes = 1380
            #expect(!overnight.isDueNow && evening.isDueNow)
            DueSlotFixture.nowMinutes = 60
            #expect(!overnight.isDueNow && evening.isDueNow)
            DueSlotFixture.nowMinutes = 120
            #expect(overnight.isDueNow)
            #expect(overnight.time == 120 && evening.time == 1380)
            #expect(DueSlotFixture(state: .pending, time: nil).isDueNow)
            #expect(!DueSlotFixture(state: .taken, time: 120).isDueNow)
        }
    }
}
''', encoding="utf-8")

with (tests / "main.swift").open("a", encoding="utf-8") as test:
    test.write('''
// The production clock conversion governs due order; displayed minutes stay untouched.
assert(Calendar.medicationClockMinutes(120) > Calendar.medicationClockMinutes(1380))
assert(Calendar.medicationClockMinutes(1380) <= Calendar.medicationClockMinutes(60))
let firstOfMonth = date("2026-06-01T01:00:00Z")
assert(calendar.medicationDayLabel(for: firstOfMonth) == date("2026-05-31T00:00:00Z"))
assert(date("2026-06-01T00:00:00Z") > calendar.medicationDayLabel(for: firstOfMonth))
defaults.set(0, forKey: Calendar.dayBoundaryHourKey)
assert(Calendar.medicationClockMinutes(120) < Calendar.medicationClockMinutes(1380))
assert(calendar.medicationDayLabel(for: firstOfMonth) == date("2026-06-01T00:00:00Z"))
defaults.set(4, forKey: Calendar.dayBoundaryHourKey)
print("Medication-day ordering regression passed: overdue evening, upcoming overnight slot, month rollover and live boundary switch.")
''')

# Both public import routes must reach the same unconditional repair-before-save path.
for relative, entry in (("Piru/Utilities/DataExportImport.swift", "static func importJSON("),
                        ("Piru/Utilities/DataExportImport+Spreadsheet.swift", "static func importSpreadsheet(")):
    body = swift_member((root / relative).read_text(encoding="utf-8"), entry)
    assert "try commitImport(context: context)" in body
assert "fileSettings" not in commit
assert commit.index("repairHistoricalDays") < commit.index("context.save()") < commit.index("DoseLogService.shared.changed()")
repair = swift_member(service_text, "nonisolated static func repairHistoricalDays(in context:")
assert repair.count("context.fetch(") == 2
assert repair.index("FetchDescriptor<DoseEntry>") < repair.index("for (day, occurrences)")
assert "context.fetch(" not in repair[repair.index("for (day, occurrences)"):]
assert "clipRect(left = left" not in shadow_patch.read_text(encoding="utf-8")
print("Prepared 70008 audit regressions: willSet reentry, shared import commit, real history database, boundary-change pipeline and exact-day occurrences")

# 70009: keep the revealed delete action outside the moving tap-catcher and
# give collapsed tray rows a native button action. Keep drag arbitration intact.
tray_views = root / "Piru/Views/QuickLog/DoseTrayViews.swift"
text = tray_views.read_text(encoding="utf-8")
anchor = """                .offset(x: offset)
                .overlay {
                    if offset != 0 {
"""
assert text.count(anchor) == 1, "Tray swipe overlay anchor changed"
text = text.replace(anchor, """                .overlay {
                    if offset != 0 {
""")
anchor = """                // The swipe gesture is invisible to assistive tech"""
assert text.count(anchor) == 1, "Tray swipe accessibility anchor changed"
text = text.replace(anchor, """                // Move the tap-catcher too, leaving the revealed delete button hittable.
                .offset(x: offset)
""" + anchor)
anchor = """        .accessibilityLabel("Remove")
        .opacity(offset < -1 ? 1 : 0)
"""
assert text.count(anchor) == 1, "Tray delete visibility anchor changed"
text = text.replace(anchor, anchor + "        .allowsHitTesting(offset < -1)\n")

row = swift_member(text, "struct TrayRow: View {")
anchor = """    var body: some View {
        // Session-row grammar"""
assert row.count(anchor) == 1, "Collapsed tray row body anchor changed"
row = row.replace(anchor, """    var body: some View {
        Button(action: expand) {
            rowContent
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Expands the editor")
    }

    private var rowContent: some View {
        // Session-row grammar""")
anchor = """        .onTapGesture(perform: expand)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Expands the editor")
"""
assert row.count(anchor) == 1, "Collapsed tray tap anchor changed"
row = row.replace(anchor, "")
text = text.replace(swift_member(text, "struct TrayRow: View {"), row)
tray_views.write_text(text, encoding="utf-8")
print("Prepared 70009 tray: moving dismiss overlay, hidden delete hit-testing off, plain edit button; swipe recognizers unchanged")
