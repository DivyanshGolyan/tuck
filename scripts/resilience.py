#!/usr/bin/env python3
"""Opt-in GUI resilience test. Stops ONLY its own fixture; CPU work is bounded.
Run from an Accessibility-authorized terminal, with production Tuck quit and
mouse/keyboard idle. All test config/files live in a fresh temporary directory.
"""
import fcntl
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
if subprocess.run(["pgrep", "-x", "Tuck"], capture_output=True).returncode == 0:
    raise SystemExit("Quit production Tuck before running the GUI test")
subprocess.run(["swift", "build"], cwd=ROOT, check=True)
root = Path(tempfile.mkdtemp(prefix="tuck-resilience-"))
config = root / "config.json"
runtime = root / "runtime.json"
production = Path.home() / ".config/tuck/config.json"
if production.exists():
    value = json.loads(production.read_text())
    value["showHidden"] = False
    config.write_text(json.dumps(value))
helper = root / "ax-control"
subprocess.run(["swiftc", str(ROOT / "scripts/AXControl.swift"), "-o", str(helper)], check=True)
fixture_app = root / "TuckFixture.app"
(fixture_app / "Contents/MacOS").mkdir(parents=True)
(fixture_app / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "local.tuck.fixture", "CFBundleExecutable": "TuckFixture", "LSUIElement": True}))
subprocess.run(["swiftc", str(ROOT / "scripts/Fixture.swift"), "-o", str(fixture_app / "Contents/MacOS/TuckFixture")], check=True)
log = open(root / "app.log", "w")
p = subprocess.Popen([str(ROOT / ".build/debug/Tuck"), "--config", str(config), "--no-prompt"], stdout=log, stderr=subprocess.STDOUT)
fixture = None
stress = []


def state():
    try:
        return json.loads(runtime.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def wait(predicate, timeout=40, interval=.05):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if p.poll() is not None:
            raise RuntimeError("Tuck exited: " + str(p.returncode))
        d = state()
        if d.get("pid") == p.pid and predicate(d):
            return d
        time.sleep(interval)
    raise RuntimeError("Timed out: " + json.dumps(state()))


def settled(d, desired):
    return (d.get("showHidden") is desired and d.get("phase") == "idle"
            and not d.get("pending") and not d.get("ambiguous")
            and d.get("error") is None and d.get("appliedRevision") == d.get("revision")
            and d.get("appliedGeneration") == d.get("workGeneration")
            and (d.get("separatorWidth") == 4 if desired else d.get("separatorWidth", 0) > 100))


def save_visibility(desired):
    with open(str(config) + ".lock", "a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        value = json.loads(config.read_text())
        value["showHidden"] = desired
        temporary = root / "editor-save.tmp"
        temporary.write_text(json.dumps(value))
        os.replace(temporary, config)


def click_once():
    # A transport timeout has unknown outcome: observe the file, never replay.
    start = time.monotonic()
    result = subprocess.run([str(helper), str(p.pid)], capture_output=True, text=True, timeout=5)
    print("AX click result", result.returncode, result.stdout.strip(), result.stderr.strip(), flush=True)
    end = time.monotonic() + 5
    while time.monotonic() < end:
        if json.loads(config.read_text()).get("showHidden") is False:
            print("Click committed during busy provider in", round(time.monotonic() - start, 3), "seconds", flush=True)
            return
        time.sleep(.025)
    raise AssertionError("One click did not commit config; it was not repeated")


try:
    baseline = wait(lambda d: settled(d, False))
    assert baseline["accessibility"]
    fixture = subprocess.Popen([str(fixture_app / "Contents/MacOS/TuckFixture")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    fixture_ids = {"local.tuck.fixture::TuckTestAlpha", "local.tuck.fixture::TuckTestBeta"}
    wait(lambda d: fixture_ids.issubset({i["id"] for i in d.get("icons", [])}) and settled(d, False))
    # Target's AX main loop is unavailable, without changing real applications.
    os.kill(fixture.pid, signal.SIGSTOP)
    reveal_start = time.monotonic()
    save_visibility(True)
    wait(lambda d: d.get("showHidden") is True and d.get("separatorWidth") == 4, timeout=3, interval=.005)
    label = subprocess.check_output([str(helper), str(p.pid), "--label"], text=True).strip()
    assert label == "Hide hidden icons", label
    print("Reveal/chevron while provider stopped in", round(time.monotonic()-reveal_start, 3), "seconds", flush=True)
    slow = wait(lambda d: d.get("showHidden") is True and d.get("phase") == "waiting" and d.get("pending"))
    assert slow.get("error") is None, slow
    assert fixture_ids.issubset({i["id"] for i in slow["icons"]}), "Busy is not disappearance"
    click_once()
    wait(lambda d: d.get("showHidden") is False and d.get("pending"))
    os.kill(fixture.pid, signal.SIGCONT)
    recovered = wait(lambda d: settled(d, False), timeout=45)
    print("Recovered without another user event; retries", recovered["retries"], flush=True)
    # Saturate available cores for four seconds, at lower scheduling priority.
    code = "import os,time; os.nice(10); end=time.monotonic()+4; x=0\nwhile time.monotonic()<end: x=(x+1)%1000003"
    import sys
    stress = [subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
              for _ in range(os.cpu_count() or 1)]
    save_visibility(True)
    wait(lambda d: settled(d, True), timeout=30)
    save_visibility(False)
    wait(lambda d: settled(d, False), timeout=30)
    for child in stress:
        child.wait(timeout=10)
    print("CPU-load convergence passed with", len(stress), "bounded workers", flush=True)
    # Cross-display regression: activating another physical bar must never turn
    # incomplete discovery into an implicit reveal. Config is still the authority.
    display_helper = root / "display-control"
    subprocess.run(["swiftc", str(ROOT / "scripts/DisplayControl.swift"), "-o", str(display_helper)], check=True)
    display_info = json.loads(subprocess.check_output([str(display_helper)]))
    original_pointer = display_info["pointer"]
    try:
        for screen in display_info["screens"]:
            # Hover an empty left part of the bar, then move into that display.
            for x, y in [(screen["x"] + 20, screen["y"] + 12),
                         (screen["x"] + screen["width"] / 2, screen["y"] + 100)]:
                subprocess.run([str(display_helper), "--move", str(x), str(y)], check=True)
                until = time.monotonic() + 2
                while time.monotonic() < until:
                    d = state()
                    assert d.get("showHidden") is False and d.get("separatorWidth") == 10000, d
                    time.sleep(.025)
            start = time.monotonic()
            save_visibility(True)
            wait(lambda d: d.get("showHidden") is True and d.get("separatorWidth") == 4, timeout=3, interval=.005)
            label = subprocess.check_output([str(helper), str(p.pid), "--label"], text=True).strip()
            assert label == "Hide hidden icons", label
            print("Reveal on display", screen["y"], "in", round(time.monotonic()-start, 3), "seconds", flush=True)
            # Let background verification finish before timing a normal hide.
            ready = wait(lambda d: settled(d, True), timeout=35)
            start = time.monotonic()
            save_visibility(False)
            physical = wait(lambda d: d.get("showHidden") is False and d.get("separatorWidth") == 10000, timeout=3, interval=.005)
            assert physical.get("fastHides", 0) > ready.get("fastHides", 0), physical
            print("Hide on display", screen["y"], "in", round(time.monotonic()-start, 3),
                  "seconds; fresh CG check", physical.get("visibilityCheckMS"), "ms; prior AX scan", ready.get("scanMS"),
                  "ms; fast hides", physical.get("fastHides"), flush=True)
            wait(lambda d: settled(d, False), timeout=35)
            label = subprocess.check_output([str(helper), str(p.pid), "--label"], text=True).strip()
            assert label == "Show hidden icons", label
        print("Cross-display visibility and chevron passed", flush=True)
    finally:
        subprocess.run([str(display_helper), "--move", str(original_pointer["x"]), str(original_pointer["y"])], check=True)
    # Workspace/display/AX events are legitimate work, even after stress ends.
    # Require a full quiet five-second interval, not a snapshot caught before
    # a queued external invalidation. Bound the search so loops still fail.
    quiet_deadline = time.monotonic() + 35
    while True:
        before = wait(lambda d: settled(d, False), timeout=35)
        cpu_before = subprocess.check_output(["ps", "-p", str(p.pid), "-o", "time="]).decode().strip()
        time.sleep(5)
        after = state()
        if (settled(after, False) and before["workGeneration"] == after["workGeneration"]):
            assert before["scans"] == after["scans"], (before, after)
            assert before["retries"] == after["retries"], (before, after)
            break
        if time.monotonic() >= quiet_deadline:
            raise AssertionError("No quiet idle interval: " + json.dumps(after))
        print("External invalidation during idle sample; waiting for quiet interval", flush=True)
    cpu_after = subprocess.check_output(["ps", "-p", str(p.pid), "-o", "time=,%cpu=,rss="]).decode().strip()
    print("Idle scans", before["scans"], "->", after["scans"], "CPU", cpu_before, "->", cpu_after, flush=True)
    print("PASS; evidence:", root, flush=True)
finally:
    if fixture and fixture.poll() is None:
        os.kill(fixture.pid, signal.SIGCONT)
    for child in stress:
        if child.poll() is None:
            child.terminate()
        child.wait(timeout=5)
    if p.poll() is None:
        subprocess.run([str(helper), str(p.pid), "--quit"], capture_output=True, timeout=5)
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill(); p.wait()
    if fixture and fixture.poll() is None:
        fixture.terminate(); fixture.wait(timeout=5)
    log.close()
    print("Logs:", root, flush=True)
