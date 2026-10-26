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
text, builds = re.subn(r"CURRENT_PROJECT_VERSION = \d+;", "CURRENT_PROJECT_VERSION = 70002;", text)
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
