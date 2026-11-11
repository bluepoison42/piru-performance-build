"""Measure Piru's tab switching and first-open cost on the phone, one installed build at a time.

    measure_nav.py tunnel                 keep the laptop adb tunnel open (run in its own terminal)
    measure_nav.py check                  device, build, conditions; sends no input
    measure_nav.py run [--trace] [--shots] [--mask N] [--rounds 3] [--settle 8] [--sheet] [--label NAME]
    measure_nav.py install <signed.apk>   adb install -r (keeps data), then prints the new build
    measure_nav.py compare <a> <b>        two result files or labels, side by side
    measure_nav.py aot [speed|reset]      compile the app ahead of time, or undo it

`run` cold-starts the app (force-stop + start), waits, opens every tab once (first open), then
cycles the tabs `--rounds` times (warm switches). Each tap is timed from the frames the app
drew after it (`dumpsys gfxinfo framestats`). Results: work/piru/fable/measure/<label>.json.

The phone is reached through the laptop by default (ANDROID_ADB_SERVER_PORT=15037); pass --usb
when it is plugged into this machine.
"""

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = Path(os.environ.get("PIRU_MEASURE_OUT", HERE / "measure"))
ADB = os.environ.get("PIRU_ADB", r"E:\Code\Projects\VPen\.tooling\sdk\platform-tools\adb.exe")
SERIAL = os.environ.get("PIRU_ADB_SERIAL", "R5CX22NJJ2N")
PACKAGE = "glass.kagerou.piru.perftest"
ACTIVITY = PACKAGE + "/piru.module.MainActivity"
CATALOG = Path(os.environ.get("PIRU_CATALOG", HERE.parent / "port18/repo/Piru/Localizable.xcstrings"))
TABS = ["Journal", "Library", "Tools", "Insights", "Search"]
# Tab centers on the 1440x3120 panel, used when the tab bar cannot be read from the UI dump.
FALLBACK_X = {"Journal": 131, "Library": 427, "Tools": 720, "Insights": 1013, "Search": 1305}
FALLBACK_Y = 2975
TUNNEL = ["ssh", "-o", "ExitOnForwardFailure=yes", "-L", "15037:127.0.0.1:5037", "laptop",
          r"C:\Users\tommy\platform-tools\adb.exe nodaemon server"]

TRACE_CONFIG = """
buffers { size_kb: 131072 fill_policy: RING_BUFFER }
buffers { size_kb: 262144 fill_policy: RING_BUFFER }
data_sources { config { name: "linux.ftrace" target_buffer: 0 ftrace_config {
  ftrace_events: "sched/sched_switch" ftrace_events: "sched/sched_wakeup" ftrace_events: "power/cpu_frequency"
  ftrace_events: "power/suspend_resume" ftrace_events: "thermal/thermal_temperature"
  atrace_categories: "gfx" atrace_categories: "view" atrace_categories: "input" atrace_categories: "dalvik"
  atrace_categories: "am" atrace_categories: "wm" atrace_categories: "binder_driver" atrace_categories: "res"
  atrace_apps: "%(package)s" } } }
data_sources { config { name: "linux.process_stats" target_buffer: 0 process_stats_config { scan_all_processes_on_start: true } } }
data_sources { config { name: "android.surfaceflinger.frametimeline" target_buffer: 0 } }
data_sources { config { name: "linux.perf" target_buffer: 1 perf_event_config {
  timebase { frequency: 2000 timestamp_clock: PERF_CLOCK_MONOTONIC }
  callstack_sampling { scope { target_cmdline: "%(package)s" } kernel_frames: false } } } }
duration_ms: %(duration_ms)d
"""


def adb(*args, binary=False, timeout=60, check=True, stdin=None):
    result = subprocess.run([ADB, "-s", SERIAL, *args], capture_output=True, timeout=timeout, input=stdin)
    if check and result.returncode:
        raise RuntimeError(f"adb {' '.join(args[:4])}: {result.stderr.decode('utf-8', 'replace').strip()}")
    return result.stdout if binary else result.stdout.decode("utf-8", "replace")


def shell(command, **kwargs):
    return adb("shell", command, **kwargs)


def installed_build():
    text = shell(f"dumpsys package {PACKAGE}")
    code = re.search(r"versionCode=(\d+)", text)
    name = re.search(r"versionName=(\S+)", text)
    if not code:
        raise SystemExit(f"{PACKAGE} is not installed on {SERIAL}")
    return int(code[1]), name[1] if name else "?"


def foreground_is_piru():
    text = shell("dumpsys activity activities")
    return any(PACKAGE + "/" in line for line in text.splitlines() if "ResumedActivity" in line)


def conditions():
    def setting(namespace, key):
        return shell(f"settings get {namespace} {key}").strip()

    battery = shell("dumpsys battery")
    thermal = re.search(r"Thermal Status: (\d+)", shell("dumpsys thermalservice"))
    dexopt = shell(f"dumpsys package dexopt | grep -A4 '\\[{PACKAGE}\\]'", check=False)
    size = re.search(r"(\d+)x(\d+)", shell("wm size"))
    return {
        "low_power": setting("global", "low_power"),
        "thermal_status": int(thermal[1]) if thermal else None,
        "battery_level": int(re.search(r"level: (\d+)", battery)[1]),
        "charging": "true" in "".join(re.findall(r"(?:AC|USB|Wireless) powered: (\w+)", battery)),
        "refresh_rate_mode": setting("secure", "refresh_rate_mode"),
        "peak_refresh_rate": setting("system", "peak_refresh_rate"),
        "accessibility_services": setting("secure", "enabled_accessibility_services"),
        "compiler_filter": sorted(set(re.findall(r"\[status=([\w-]+)\]", dexopt))),
        "screen": [int(size[1]), int(size[2])] if size else None,
    }


def tab_titles():
    """Every language's title for each tab, so the tab bar is found whatever the app language."""
    strings = json.loads(CATALOG.read_text(encoding="utf-8"))["strings"] if CATALOG.exists() else {}
    titles = {}
    for key in TABS + ["Record an entry"]:
        values = {key}
        for localization in strings.get(key, {}).get("localizations", {}).values():
            value = localization.get("stringUnit", {}).get("value")
            if value:
                values.add(value)
        titles[key] = values
    return titles


def ui_nodes():
    remote = "/data/local/tmp/piru-measure.xml"
    OUT.mkdir(parents=True, exist_ok=True)
    # Pull the file instead of parsing an adb command's stdout, which can include diagnostics.
    dump = shell(f"rm -f {remote}; uiautomator dump --compressed {remote}", timeout=40)
    (OUT / "ui-dump.txt").write_text(dump, encoding="utf-8")
    local = OUT / "ui-latest.xml"
    adb("pull", remote, str(local))
    raw = local.read_bytes()
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as error:
        raise RuntimeError(f"Invalid UI XML {local}: {raw[:160]!r}; dump: {dump.strip()}") from error
    nodes = []
    for node in root.iter("node"):
        a = node.attrib
        if a.get("package") != PACKAGE:
            continue
        x1, y1, x2, y2 = map(int, re.findall(r"\d+", a["bounds"]))
        nodes.append({"text": a.get("text") or a.get("content-desc") or "", "x": (x1 + x2) // 2, "y": (y1 + y2) // 2, "top": y1})
    return nodes


def assert_page(tab, screen):
    height = screen[1] if screen else 3120
    nodes = ui_nodes()
    titles = tab_titles()[tab]
    if not any(node["text"] in titles and node["top"] < height * 0.5 for node in nodes):
        seen = [node["text"] for node in nodes if node["text"] and node["top"] < height * 0.85]
        raise RuntimeError(f"Did not reach {tab}: visible page text {seen[:30]}")


def locate_tabs(screen):
    titles = tab_titles()
    height = screen[1] if screen else 3120
    found = {}
    try:
        for node in ui_nodes():
            for tab in TABS:
                if node["text"] in titles[tab] and node["top"] > height * 0.85:
                    found[tab] = (node["x"], node["y"] - 40)
    except Exception as error:  # the dump fails while the screen animates; the fixed centers still work
        print("UI dump failed, using fixed tab positions:", error)
    if len(found) < 2:
        scale_x = (screen[0] / 1440) if screen else 1
        scale_y = (screen[1] / 3120) if screen else 1
        found = {tab: (round(x * scale_x), round(FALLBACK_Y * scale_y)) for tab, x in FALLBACK_X.items()}
        source = "fixed"
    else:
        source = "ui-dump"
    return found, source


def parse_frames(text):
    """Rows of the app's frame-timing ring: (intended_vsync_ns, completed_ns, handled_input)."""
    rows = {}
    for block in text.split("---PROFILEDATA---")[1::2]:
        lines = [line for line in block.strip().splitlines() if line]
        if not lines:
            continue
        header = lines[0].rstrip(",").split(",")
        intended_at, completed_at = header.index("IntendedVsync"), header.index("FrameCompleted")
        # Android 12 and later name the frame's input event; older releases give its time.
        input_at = next((header.index(name) for name in ("InputEventId", "OldestInputEvent") if name in header), None)
        for line in lines[1:]:
            cells = line.rstrip(",").split(",")
            if len(cells) < len(header):
                continue
            intended, completed = int(cells[intended_at]), int(cells[completed_at])
            if completed > intended > 0:
                rows[intended] = (intended, completed, input_at is not None and cells[input_at] not in ("0", ""))
    return [rows[key] for key in sorted(rows)]


def frames():
    return parse_frames(shell(f"dumpsys gfxinfo {PACKAGE} framestats"))


def timed(action, wait):
    """Run `action` (one input), wait, and describe the frames drawn after it."""
    if not foreground_is_piru():
        raise SystemExit("Piru is not in the foreground; stopped without sending input.")
    before = frames()
    last = before[-1][0] if before else 0
    action()
    time.sleep(wait)
    after = [row for row in frames() if row[0] > last]
    durations = [(completed - intended) / 1e6 for intended, completed, _ in after]
    worst = max(range(len(after)), key=lambda i: durations[i]) if after else None
    touched = next((intended for intended, _, handled_input in after if handled_input), after[0][0] if after else None)
    return {
        "frames": len(after),
        "worst_ms": round(durations[worst], 1) if after else None,
        "over_32ms": sum(1 for d in durations if d > 32),
        "over_100ms": sum(1 for d in durations if d > 100),
        "slow_total_ms": round(sum(d for d in durations if d > 32), 1),
        # From the frame that took the touch to the slowest frame reaching the screen.
        "touch_to_worst_ms": round((after[worst][1] - touched) / 1e6, 1) if after else None,
        "durations_ms": [round(d, 1) for d in durations],
    }


def tap(point):
    return lambda: shell(f"input -d 0 tap {point[0]} {point[1]}")


def start_trace(label, seconds):
    config = TRACE_CONFIG % {"package": PACKAGE, "duration_ms": seconds * 1000}
    remote = f"/data/misc/perfetto-traces/piru-{label}.perfetto-trace"
    process = subprocess.Popen([ADB, "-s", SERIAL, "shell", f"perfetto --txt -c - -o {remote}"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    process.stdin.write(config.encode())
    process.stdin.close()
    time.sleep(2)
    return process, remote


def run(args):
    code, name = installed_build()
    label = args.label or f"v{code}" + (f"-mask{args.mask}" if args.mask else "")
    OUT.mkdir(exist_ok=True)
    state = conditions()
    print(f"{PACKAGE} {name} ({code}) on {SERIAL}; conditions: {json.dumps(state, ensure_ascii=False)}")
    tabs_expected = 1 + len(TABS) - 1 + args.rounds * len(TABS)
    trace = None
    if args.trace:
        trace = start_trace(label, 12 + args.settle + int(tabs_expected * (args.wait + 1.5)) + (10 if args.sheet else 0))

    shell(f"am force-stop {PACKAGE}")
    time.sleep(1)
    extras = f" --ei piru_next_mask {args.mask}" if args.mask else ""
    launch = shell(f"am start -W -n {ACTIVITY}{extras}")
    total = re.search(r"TotalTime: (\d+)", launch)
    time.sleep(args.settle)
    positions, source = locate_tabs(state["screen"])
    order = [tab for tab in TABS if tab in positions]
    if set(order) != set(TABS):
        raise RuntimeError(f"Missing tabs in UI dump: {set(TABS) - set(order)}")
    print(f"launch TotalTime {total[1] if total else '?'} ms; tabs from {source}: {positions}")

    result = {"label": label, "version_code": code, "version_name": name, "mask": args.mask, "settle_s": args.settle,
              "wait_s": args.wait, "launch_total_ms": int(total[1]) if total else None, "conditions": state,
              "tab_source": source, "first_open": {}, "warm": {tab: [] for tab in order}, "sheet": []}
    # The app starts on the tab it was left on; every other tab is opened for the first time here.
    for tab in order[1:] + order[:1]:
        result["first_open"][tab] = timed(tap(positions[tab]), args.wait)
        if args.shots:
            (OUT / f"{label}-{tab}.png").write_bytes(adb("exec-out", "screencap", "-p", binary=True))
        assert_page(tab, state["screen"])
        print(f"first open {tab:9} worst {result['first_open'][tab]['worst_ms']} ms, slow total {result['first_open'][tab]['slow_total_ms']} ms")
    for _ in range(args.rounds):
        for tab in order[1:] + order[:1]:
            result["warm"][tab].append(timed(tap(positions[tab]), args.wait))
            assert_page(tab, state["screen"])
    if args.sheet:
        titles = tab_titles()["Record an entry"]
        button = next((node for node in ui_nodes() if node["text"] in titles), None)
        if button:
            for _ in range(args.rounds):
                opened = timed(tap((button["x"], button["y"])), args.wait)
                closed = timed(lambda: shell("input -d 0 keyevent 4"), args.wait)
                result["sheet"].append({"open": opened, "close": closed})
        else:
            print("Record-an-entry button not found; sheet timing skipped.")
    result["gfxinfo"] = shell(f"dumpsys gfxinfo {PACKAGE}").split("Pipeline=")[0]
    result["conditions_after"] = conditions()

    if trace:
        process, remote = trace
        process.wait(timeout=180)
        local = OUT / f"{label}.perfetto-trace"
        adb("pull", remote, str(local), timeout=300)
        shell(f"rm {remote}", check=False)
        result["trace"] = str(local)
        print("trace:", local, "(open at https://ui.perfetto.dev)")
    path = OUT / f"{label}.json"
    if path.exists():
        path = OUT / f"{label}-{time.strftime('%H%M%S')}.json"
    path.write_text(json.dumps(result, indent=1, ensure_ascii=False), encoding="utf-8")
    print("saved", path)
    summarize(result)


def spread(values):
    values = [v for v in values if v is not None]
    if not values:
        return "-"
    return f"{statistics.median(values):.0f} (max {max(values):.0f})"


def rows_of(result):
    rows = {}
    for tab, sample in result["first_open"].items():
        rows[f"first open  {tab}"] = (f"{sample['worst_ms']:.0f}" if sample["worst_ms"] is not None else "-", f"{sample['slow_total_ms']:.0f}")
    for tab, samples in result["warm"].items():
        rows[f"warm switch {tab}"] = (spread([s["worst_ms"] for s in samples]), spread([s["slow_total_ms"] for s in samples]))
    every = [s for samples in result["warm"].values() for s in samples]
    rows["warm switch ALL"] = (spread([s["worst_ms"] for s in every]), spread([s["slow_total_ms"] for s in every]))
    for phase in ("open", "close"):
        samples = [s[phase] for s in result.get("sheet", [])]
        if samples:
            rows[f"sheet {phase}"] = (spread([s["worst_ms"] for s in samples]), spread([s["slow_total_ms"] for s in samples]))
    return rows


def summarize(result):
    print(f"\n{result['label']}: worst frame ms | slow-frame total ms   (warm rows: median (max))")
    for name, (worst, slow) in rows_of(result).items():
        print(f"  {name:24} {worst:>16} | {slow:>16}")


def load(name):
    path = Path(name) if Path(name).exists() else OUT / f"{name}.json"
    return json.loads(path.read_text(encoding="utf-8"))


def compare(args):
    a, b = load(args.a), load(args.b)
    left, right = rows_of(a), rows_of(b)
    print(f"{'worst frame ms | slow total ms':24} {a['label']:>28}   {b['label']:>28}")
    for name in left:
        l, r = left[name], right.get(name, ("-", "-"))
        print(f"{name:24} {l[0] + ' | ' + l[1]:>28}   {r[0] + ' | ' + r[1]:>28}")
    for result in (a, b):
        c = result["conditions"]
        print(f"{result['label']}: low_power={c['low_power']} thermal={c['thermal_status']} battery={c['battery_level']} "
              f"filter={c['compiler_filter']} launch={result['launch_total_ms']} ms")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--usb", action="store_true", help="the phone is on this machine's own adb server")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("tunnel")
    commands.add_parser("check")
    runner = commands.add_parser("run")
    runner.add_argument("--label")
    runner.add_argument("--rounds", type=int, default=3)
    runner.add_argument("--settle", type=float, default=8, help="seconds between launch and the first tap")
    runner.add_argument("--wait", type=float, default=1.5, help="seconds of frames collected after each tap")
    runner.add_argument("--mask", type=int, default=0, help="piru_next_mask for this launch (70019: 8 no prepared tabs, 16 no retained tabs, 32 hidden tabs not measured, 64 prepared tabs run no tasks)")
    runner.add_argument("--trace", action="store_true", help="record a Perfetto trace with call stacks")
    runner.add_argument("--shots", action="store_true", help="save a screenshot of each tab after its first open")
    runner.add_argument("--sheet", action="store_true", help="also time opening and closing the Record-an-entry sheet")
    installer = commands.add_parser("install")
    installer.add_argument("apk")
    comparer = commands.add_parser("compare")
    comparer.add_argument("a")
    comparer.add_argument("b")
    aot = commands.add_parser("aot")
    aot.add_argument("mode", nargs="?", default="speed", choices=["speed", "speed-profile", "reset"])
    args = parser.parse_args()

    if not args.usb:
        os.environ["ANDROID_ADB_SERVER_PORT"] = "15037"
    if args.command == "tunnel":
        print("Tunnel to the laptop's adb server on port 15037; leave this running, Ctrl+C to close.")
        raise SystemExit(subprocess.call(TUNNEL))
    if args.command == "check":
        code, name = installed_build()
        print(f"{PACKAGE} {name} ({code}); foreground: {foreground_is_piru()}")
        print(json.dumps(conditions(), indent=1, ensure_ascii=False))
    elif args.command == "run":
        run(args)
    elif args.command == "install":
        before = installed_build()
        print("installed before:", before)
        print(adb("install", "-r", args.apk, timeout=900).strip())
        print("installed now:", installed_build())
    elif args.command == "compare":
        compare(args)
    elif args.command == "aot":
        command = f"cmd package compile --reset {PACKAGE}" if args.mode == "reset" else f"cmd package compile -m {args.mode} -f {PACKAGE}"
        print(shell(command, timeout=900).strip())
        print(conditions()["compiler_filter"])


if __name__ == "__main__":
    main()
