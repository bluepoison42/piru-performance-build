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
text, builds = re.subn(r"CURRENT_PROJECT_VERSION = \d+;", "CURRENT_PROJECT_VERSION = 70001;", text)
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
