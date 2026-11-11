"""Run the baseline and candidate Piru builds in the CI emulator: install, pass onboarding,
open every tab, switch between them, and keep frame timings, screenshots and the log.

    smoke.py <apk dir> <out dir>

The emulator translates the app's arm64 libraries, so the timings only compare builds with
each other; they say nothing about a phone.
"""
import glob
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
APKS, OUT = Path(sys.argv[1]), Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)
os.environ.update(PIRU_ADB="adb", PIRU_ADB_SERIAL="emulator-5554", PIRU_MEASURE_OUT=str(OUT), PIRU_CATALOG=str(HERE / "none"))
sys.path.insert(0, str(HERE))
import measure_nav as m  # noqa: E402


def shot(name):
    (OUT / f"{name}.png").write_bytes(m.adb("exec-out", "screencap", "-p", binary=True))


def tap_text(nodes, *candidates):
    for node in nodes:
        if node["text"] in candidates:
            m.shell(f"input tap {node['x']} {node['y']}")
            return node["text"]
    return None


def reach_tabs(name):
    """Past onboarding and any launch sheet, to the tab bar."""
    for step in range(12):
        time.sleep(6)
        try:
            nodes = m.ui_nodes()
        except Exception as error:
            print(f"[{name}] step {step}: UI dump failed: {error}", flush=True)
            continue
        seen = [node["text"] for node in nodes if node["text"]]
        print(f"[{name}] step {step}: {seen[:25]}", flush=True)
        if {"Journal", "Library"} <= set(seen) and "Skip" not in seen:
            return True
        if not tap_text(nodes, "Skip", "Not Now", "Continue", "Get Started", "Done", "OK", "Allow", "Close"):
            m.shell("input keyevent 4")
    return False


def measure(label, mask=0):
    command = [sys.executable, str(HERE / "measure_nav.py"), "--usb", "run", "--label", label, "--rounds", "1",
               "--settle", "25", "--wait", "4", "--shots"] + (["--mask", str(mask)] if mask else [])
    print("::group::" + label, flush=True)
    code = subprocess.call(command)
    print("::endgroup::", flush=True)
    return code


def install(apk, name):
    print(f"installing {apk}", flush=True)
    print(m.adb("install", "--no-incremental", "-r", apk, timeout=900))
    m.shell(f"pm grant {m.PACKAGE} android.permission.POST_NOTIFICATIONS", check=False)
    m.shell(f"am start -W -n {m.ACTIVITY}")
    ok = reach_tabs(name)
    shot(f"{name}-after-launch")
    return ok


def main():
    m.shell("settings put global window_animation_scale 1; settings put global transition_animation_scale 1; settings put global animator_duration_scale 1")
    abi = m.shell("getprop ro.product.cpu.abilist").strip()
    print(abi, m.shell("wm size"), flush=True)
    if "arm64-v8a" not in abi.split(","):
        raise RuntimeError(f"The emulator cannot run this arm64-v8a APK: {abi}")
    m.adb("logcat", "-c")
    status = {}
    baseline = glob.glob(str(APKS / "baseline/*-smoke.apk"))
    candidate = glob.glob(str(APKS / "candidate/*-smoke.apk"))
    status["baseline_reached_tabs"] = install(baseline[0], "baseline")
    if status["baseline_reached_tabs"]:
        status["baseline_run"] = measure("emu-baseline")
    if candidate:
        status["candidate_reached_tabs"] = install(candidate[0], "candidate")
        if status["candidate_reached_tabs"]:
            status["candidate_run"] = measure("emu-candidate")
    log = m.adb("logcat", "-d", "-v", "threadtime", timeout=120)
    (OUT / "logcat.txt").write_text(log, encoding="utf-8")
    fatal = [line for line in log.splitlines() if re.search(r"FATAL EXCEPTION|Fatal signal|AndroidRuntime: |F DEBUG|ANR in", line)]
    status["fatal_lines"] = fatal[:40]
    status["foreground_at_end"] = m.foreground_is_piru()
    (OUT / "status.json").write_text(json.dumps(status, indent=1), encoding="utf-8")
    print(json.dumps(status, indent=1))
    results = sorted(OUT.glob("emu-*.json"))
    for path in results:
        m.summarize(json.loads(path.read_text(encoding="utf-8")))
    failed = (fatal or not status["baseline_reached_tabs"] or status.get("baseline_run") != 0
              or (candidate and (not status.get("candidate_reached_tabs") or status.get("candidate_run") != 0))
              or not status["foreground_at_end"])
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
