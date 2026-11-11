#!/usr/bin/env python3
"""Alternating release AXPress benchmarks. Uses temporary config copies only."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("baseline", type=Path)
parser.add_argument("candidate", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
helper = out / "visibility-benchmark"
control = out / "ax-control"
if subprocess.run(["pgrep", "-x", "Tuck"], capture_output=True).returncode == 0:
    raise SystemExit("Quit production Tuck before benchmarking")
source = json.loads((Path.home() / ".config/tuck/config.json").read_text())
source["showHidden"] = False
results = []

def read_state(path):
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}

def ready(p, runtime, desired):
    end = time.monotonic() + 40
    while time.monotonic() < end:
        if p.poll() is not None:
            raise RuntimeError("App exited: " + str(p.returncode))
        d = read_state(runtime)
        if (d.get("pid") == p.pid and d.get("showHidden") is desired
                and d.get("phase") == "idle" and not d.get("pending")
                and d.get("error") is None and not d.get("ambiguous")
                and d.get("appliedRevision") == d.get("revision")
                and d.get("appliedGeneration") == d.get("workGeneration")):
            return d
        time.sleep(.025)
    raise RuntimeError("Not settled: " + json.dumps(read_state(runtime)))

def action(p, config, desired):
    result = subprocess.run([str(helper), str(p.pid), str(config), str(desired).lower()],
                            capture_output=True, text=True, timeout=15)
    value = json.loads(result.stdout)
    if result.returncode != 0 or not value.get("success"):
        raise RuntimeError("Action failed: " + json.dumps(value) + result.stderr)
    return value

def trial(label, bundle, index, profile=False):
    directory = out / ("profile" if profile else f"{index:02d}-{label}")
    directory.mkdir(exist_ok=True)
    config = directory / "config.json"
    config.write_text(json.dumps(source))
    runtime = directory / "runtime.json"
    (directory / "load.txt").write_text(subprocess.check_output(["uptime"], text=True)
        + subprocess.check_output(["ps", "-A", "-o", "pid=,pcpu=,comm="], text=True))
    with (directory / "app.log").open("w") as log:
        p = subprocess.Popen([str(bundle / "Contents/MacOS/Tuck"), "--config", str(config), "--no-prompt"],
                             stdout=log, stderr=subprocess.STDOUT)
        sampler = None
        try:
            initial = ready(p, runtime, False)
            assert initial["accessibility"]
            reveal = action(p, config, True)
            shown = ready(p, runtime, True)
            if profile:
                sampler = subprocess.Popen(["sample", str(p.pid), "1", "1", "-file", str(directory / "sample.txt")],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                time.sleep(.05)
            hide = action(p, config, False)
            hidden = ready(p, runtime, False)
            if sampler:
                sampler.wait(timeout=10)
            value = {"variant": label, "run": index, "profile": profile,
                     "reveal": reveal, "hide": hide,
                     "shownRuntime": shown, "hiddenRuntime": hidden}
            (directory / "result.json").write_text(json.dumps(value, indent=2))
            if not profile:
                results.append(value)
                (out / "results.json").write_text(json.dumps(results, indent=2))
                print(label, index, "hideMS", round(hide["elapsedMS"], 3),
                      "fastHides", hidden.get("fastHides"), flush=True)
        finally:
            if sampler and sampler.poll() is None:
                sampler.terminate(); sampler.wait(timeout=5)
            if p.poll() is None:
                subprocess.run([str(control), str(p.pid), "--quit"], capture_output=True, timeout=5)
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    p.kill(); p.wait()

try:
    trial("baseline", args.baseline.resolve(), 0, profile=True)
    for index in range(1, 6):
        trial("baseline", args.baseline.resolve(), index)
        trial("candidate", args.candidate.resolve(), index)
    summary = {"runsPerVariant": 5, "errors": 0, "endPoint": "AXPress start through concurrently observed CG separator geometry and config persistence; AX label verified after action returns"}
    for label in ["baseline", "candidate"]:
        values = [r["hide"]["elapsedMS"] for r in results if r["variant"] == label]
        summary[label] = {"medianMS": statistics.median(values), "minMS": min(values), "maxMS": max(values), "samplesMS": values}
    summary["medianReductionMS"] = summary["baseline"]["medianMS"] - summary["candidate"]["medianMS"]
    (out / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2), flush=True)
finally:
    if subprocess.run(["pgrep", "-x", "Tuck"], capture_output=True).returncode != 0:
        subprocess.run(["open", str(Path.home() / "Applications/Tuck.app")], check=True)
