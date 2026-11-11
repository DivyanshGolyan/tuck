#!/usr/bin/env python3
"""Check a running, disposable-config Tuck against MenuFixture.swift.

Launch the correctly signed app through LaunchServices first. This driver refuses
Tuck's default config and never quits unrelated apps or changes privacy grants.
The busy scenario suspends then terminates only the disposable menu fixture.
"""
import argparse
import json
import os
import signal
import subprocess
from pathlib import Path
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--runtime', required=True, type=Path)
parser.add_argument('--fixture-command', required=True, type=Path)
parser.add_argument('--fixture-log', required=True, type=Path)
parser.add_argument('--scenario', choices=['stale', 'live', 'busy', 'idle'], required=True)
parser.add_argument('--report', required=True, type=Path)
parser.add_argument('--hold-seconds', type=float, default=6, help='Continuous real-menu guard observation interval')
args = parser.parse_args()
records = []


def state():
    try:
        return json.loads(args.runtime.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def record(message, value=None):
    entry = {'message': message, 'time': time.time()}
    if value is not None:
        keys = ['pid', 'phase', 'pending', 'showHidden', 'separatorWidth', 'moves',
                'scans', 'revision', 'appliedRevision', 'workGeneration', 'error',
                'menuOpen', 'menuCount', 'menuChecks', 'menuCheckResult', 'inputBusy']
        entry['state'] = {key: value.get(key) for key in keys}
    records.append(entry)
    print(message, json.dumps(entry.get('state', {}), sort_keys=True), flush=True)


def wait(predicate, label, timeout=15):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        value = state()
        if predicate(value):
            return value
        time.sleep(.05)
    raise AssertionError(label + ': ' + json.dumps(state(), sort_keys=True))


def settled(value, showing):
    return (value.get('phase') == 'idle' and value.get('pending') is False
            and value.get('revision') == value.get('appliedRevision')
            and value.get('showHidden') is showing and value.get('error') is None
            and (value.get('separatorWidth', 0) <= 100 if showing
                 else value.get('separatorWidth', 0) > 100))


initial = state()
config_path = Path(initial.get('config', '')).resolve()
if not initial or not initial.get('pid') or not config_path.is_file():
    raise SystemExit('Runtime must identify a running test app and its config')
if config_path == (Path.home()/'.config/tuck/config.json').resolve():
    raise SystemExit('Refusing to edit the default user config; launch a disposable copy')
original_visibility = json.loads(config_path.read_text()).get('showHidden', False)


def visibility(showing):
    data = json.loads(config_path.read_text())
    if data.get('showHidden', False) is showing:
        return
    data['showHidden'] = showing
    temporary = config_path.with_name(config_path.name + '.menu-check.tmp')
    temporary.write_text(json.dumps(data, indent=2) + '\n')
    os.replace(temporary, config_path)


def command(text, receipt):
    offset = len(args.fixture_log.read_text())
    temporary = args.fixture_command.with_suffix('.tmp')
    temporary.write_text(text + '\n')
    os.replace(temporary, args.fixture_command)
    until = time.monotonic() + 5
    while time.monotonic() < until:
        if receipt in args.fixture_log.read_text()[offset:]:
            return
        time.sleep(.05)
    raise AssertionError('Fixture did not acknowledge ' + text)


failed = None
fixture_pid = None
fixture_owned = False
try:
    visibility(True)
    ready = wait(lambda d: settled(d, True), 'Test app must settle revealed', 40)
    record('READY', ready)
    if args.scenario == 'stale':
        command('stale-open', 'posted-stale-open')
        time.sleep(.4)
        visibility(False)
        recovered = wait(lambda d: settled(d, False),
                         'Stale menu must recover without another input or config event', 12)
        record('PASS stale menu recovered without another input or config event', recovered)
    elif args.scenario == 'live':
        fixture_offset = len(args.fixture_log.read_text())
        command('open 9', 'will-open')
        time.sleep(.2)
        before = state()
        visibility(False)
        blocked = wait(lambda d: d.get('phase') == 'waiting-input', 'Real menu must block layout', 3)
        record('REAL MENU BLOCKED', blocked)
        until = time.monotonic() + args.hold_seconds
        while time.monotonic() < until:
            current = state()
            assert 'open-returned' not in args.fixture_log.read_text()[fixture_offset:], 'Fixture menu actually closed early; live hold is inconclusive'
            assert current.get('separatorWidth') == before.get('separatorWidth'), 'Layout hid icons while a real menu was open'
            assert current.get('moves') == before.get('moves'), 'Layout moved icons while a real menu was open'
            assert current.get('phase') == 'waiting-input', 'Layout escaped the real-menu guard'
            time.sleep(.05)
        record('PASS real menu retained the layout guard', state())
        recovered = wait(lambda d: settled(d, False), 'Menu close must release pending hide', 15)
        record('PASS native menu close released pending hide', recovered)
    elif args.scenario == 'busy':
        fixture_pid = json.loads(args.fixture_log.read_text().splitlines()[0])['pid']
        fixture_executable = subprocess.check_output(['ps', '-p', str(fixture_pid), '-o', 'comm='], text=True).strip()
        assert Path(fixture_executable).name in ['MenuFixture', 'probe-fixture'], 'Refusing to signal a non-fixture process'
        fixture_owned = True
        command('open 30', 'will-open')
        wait(lambda d: d.get('menuOpen') is True, 'Native fixture must be latched before suspension')
        before = state()
        os.kill(fixture_pid, signal.SIGSTOP)
        try:
            visibility(False)
            unknown = wait(lambda d: d.get('menuChecks', 0) > before.get('menuChecks', 0)
                           and 'unknown=' in (d.get('menuCheckResult') or '')
                           and 'unknown=0' not in (d.get('menuCheckResult') or ''),
                           'Busy provider must yield unknown evidence', 8)
            assert unknown.get('menuOpen') is True, 'Timeout erased the menu latch'
            assert unknown.get('separatorWidth') == before.get('separatorWidth'), 'Timeout allowed a hide'
            assert unknown.get('moves') == before.get('moves'), 'Timeout allowed a move'
            record('PASS unresponsive native provider retained the menu guard', unknown)
        finally:
            os.kill(fixture_pid, signal.SIGCONT)
        os.kill(fixture_pid, signal.SIGTERM)
        recovered = wait(lambda d: settled(d, False), 'Exiting native provider must release pending hide', 20)
        record('PASS native provider exit released pending hide', recovered)
    else:
        before = state()
        until = time.monotonic() + 6
        while time.monotonic() < until:
            current = state()
            for key in ['scans', 'moves', 'menuChecks', 'workGeneration']:
                assert current.get(key) == before.get(key), key + ' changed while idle'
            assert settled(current, True), 'Test app left the idle state'
            time.sleep(.1)
        record('PASS no menu polling or layout work while idle', state())
except Exception as error:
    failed = str(error)
    record('FAIL ' + args.scenario, state())
    print(type(error).__name__ + ': ' + failed, flush=True)
finally:
    try:
        if args.scenario == 'busy' and fixture_owned:
            try:
                os.kill(fixture_pid, signal.SIGCONT)
                os.kill(fixture_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        else:
            command('close', 'command-close')
            command('stale-close', 'posted-stale-close')
        visibility(original_visibility)
    except Exception as error:
        records.append({'cleanupError': str(error)})
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps({'scenario': args.scenario, 'passed': failed is None,
                                      'error': failed, 'records': records}, indent=2) + '\n')
if failed:
    raise SystemExit(1)
