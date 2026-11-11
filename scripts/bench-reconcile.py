#!/usr/bin/env python3
"""Alternating full-reconcile benchmark against the real menu bar.

Usage: bench-reconcile.py OUTPUT LABEL=APP [LABEL=APP ...] [--rounds N] [--samples N]

Each launch uses a temporary copy of the production config with showHidden
true, so nothing is hidden and no icon is moved. Touching the config forces one
full reconcile pass; the app reports its wall time in runtime.json.
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
parser.add_argument("variants", nargs="+")
parser.add_argument("--rounds", type=int, default=3)
parser.add_argument("--samples", type=int, default=6)
args = parser.parse_args()
variants = [(v.split("=", 1)[0], Path(v.split("=", 1)[1]).resolve()) for v in args.variants]
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
if subprocess.run(["pgrep", "-x", "Tuck"], capture_output=True).returncode == 0:
    raise SystemExit("Quit production Tuck before benchmarking")
source = json.loads((Path.home() / ".config/tuck/config.json").read_text())
source["showHidden"] = True


def state(path):
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def settled(d, pid):
    return (d.get("pid") == pid and d.get("phase") == "idle" and not d.get("pending")
            and d.get("error") is None and not d.get("ambiguous")
            and d.get("appliedRevision") == d.get("revision"))


def wait(p, runtime, after, timeout=40):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if p.poll() is not None:
            raise RuntimeError("App exited: " + str(p.returncode))
        d = state(runtime)
        if settled(d, p.pid) and d.get("reconciles", 0) > after:
            return d
        time.sleep(.02)
    return None


samples = {label: [] for label, _ in variants}
phases = {label: [] for label, _ in variants}
errors = {label: 0 for label, _ in variants}
work = {label: {"reconciles": 0, "scans": 0, "moves": 0, "icons": []} for label, _ in variants}
for round_index in range(args.rounds):
    order = variants if round_index % 2 == 0 else list(reversed(variants))
    for label, bundle in order:
        directory = out / f"{round_index:02d}-{label}"
        directory.mkdir(exist_ok=True)
        config = directory / "config.json"
        config.write_text(json.dumps(source))
        runtime = directory / "runtime.json"
        (directory / "load.txt").write_text(subprocess.check_output(["uptime"], text=True))
        with (directory / "app.log").open("w") as log:
            p = subprocess.Popen([str(bundle / "Contents/MacOS/Tuck"), "--config", str(config), "--no-prompt"],
                                 stdout=log, stderr=subprocess.STDOUT)
            try:
                d = wait(p, runtime, 0, timeout=90)
                if d is None or not d.get("accessibility"):
                    errors[label] += args.samples
                    continue
                start = d
                for _ in range(args.samples):
                    before = d["reconciles"]
                    os.utime(config)
                    nxt = wait(p, runtime, before)
                    if nxt is None:
                        errors[label] += 1
                        d = state(runtime)
                        if "reconciles" not in d:
                            break
                        continue
                    d = nxt
                    samples[label].append(d["reconcileMS"])
                    phases[label].append(d["reconcilePhases"])
                    work[label]["icons"].append(len(d["icons"]))
                    time.sleep(.3)
                for key in ("reconciles", "scans", "moves"):
                    work[label][key] += d[key] - start[key]
            finally:
                p.terminate()
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    p.kill()
        time.sleep(1)

summary = {}
for label, _ in variants:
    values = samples[label]
    names = sorted({k for item in phases[label] for k in item})
    summary[label] = {
        "n": len(values), "errors": errors[label],
        "median_ms": round(statistics.median(values), 1) if values else None,
        "min_ms": round(min(values), 1) if values else None,
        "max_ms": round(max(values), 1) if values else None,
        "phase_median_ms": {k: round(statistics.median([item.get(k, 0) for item in phases[label]]), 1) for k in names},
        "reconciles": work[label]["reconciles"], "scans": work[label]["scans"], "moves": work[label]["moves"],
        "icons": sorted(set(work[label]["icons"])), "samples_ms": [round(v, 1) for v in values],
    }
(out / "summary.json").write_text(json.dumps(summary, indent=2))
for label, value in summary.items():
    print(label, json.dumps({k: v for k, v in value.items() if k != "samples_ms"}))
