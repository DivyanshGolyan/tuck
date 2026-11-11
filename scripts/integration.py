#!/usr/bin/env python3
"""Opt-in GUI test. Creates two fixture icons, hides/reorders them, then restores.
Run from an Accessibility-authorized terminal with no other Tuck running.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
if subprocess.run(['pgrep', '-x', 'Tuck'], stdout=subprocess.DEVNULL).returncode == 0:
    raise SystemExit('Refusing GUI test while another Tuck is running')
subprocess.run(['swift', 'build'], cwd=ROOT, check=True)
subprocess.run(['swiftc', str(ROOT/'scripts/AXControl.swift'), '-o', '/tmp/tuck-ax-control'], check=True)
root = Path(tempfile.mkdtemp(prefix='tuck-integration-'))
config = root/'config.json'
runtime = root/'runtime.json'
fixture_app = root/'TuckFixture.app'
(fixture_app/'Contents/MacOS').mkdir(parents=True)
import plistlib
(fixture_app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.tuck.fixture','CFBundleExecutable':'TuckFixture','LSUIElement':True}))
subprocess.run(['swiftc',str(ROOT/'scripts/Fixture.swift'),'-o',str(fixture_app/'Contents/MacOS/TuckFixture')], check=True)
fixture = None
log = open(root/'stdout.log', 'w')
p = subprocess.Popen([str(ROOT/'.build/debug/Tuck'), '--config', str(config), '--no-prompt'], stdout=log, stderr=subprocess.STDOUT)
original = None

def state():
    try: return json.loads(runtime.read_text())
    except (FileNotFoundError, json.JSONDecodeError): return {}

def wait(predicate, timeout=35):
    end = time.monotonic()+timeout
    while time.monotonic() < end:
        if p.poll() is not None: raise RuntimeError('Tuck exited; is another instance running?')
        value = state()
        if predicate(value): return value
        time.sleep(.1)
    raise RuntimeError('Timed out: '+str(state()))

def settled(value):
    return (value.get('pid') == p.pid and value.get('phase') == 'idle'
            and value.get('pending') is False and value.get('ambiguous') == []
            and value.get('revision') is not None
            and value.get('appliedRevision') == value.get('revision')
            and value.get('workGeneration') is not None
            and value.get('appliedGeneration') == value.get('workGeneration')
            and value.get('error') is None)

def quit_app():
    if p.poll() is not None: return
    subprocess.run(['/tmp/tuck-ax-control', str(p.pid), '--quit'],
                   check=True, capture_output=True, timeout=5)
    p.wait(timeout=10)

def show(label, value):
    print(label, {k:value.get(k) for k in ['pid','phase','pending','scans','moves','error','controlX','separatorX','separatorWidth','showHidden','revision','appliedRevision','workGeneration','appliedGeneration','hiddenIDs','ambiguous']}, flush=True)

def persisted_visibility(expected):
    try: return json.loads(config.read_text()).get('showHidden') is expected
    except (FileNotFoundError, json.JSONDecodeError): return False

def visible_state(value, expected):
    return (settled(value) and value.get('showHidden') is expected
            and (value.get('separatorWidth') == 4 if expected else value.get('separatorWidth', 0) > 100)
            and persisted_visibility(expected))

def visibility(expected):
    return wait(lambda d: visible_state(d, expected))

def click():
    # One action only: retrying a toggle could undo a successful first press.
    subprocess.run(['/tmp/tuck-ax-control', str(p.pid)], check=True)

def save(value):
    temporary = root/'editor-save.tmp'
    temporary.write_text(json.dumps(value, indent=2))
    os.replace(temporary, config)

try:
    d = wait(lambda d: settled(d) and len(d.get('icons', [])) > 2)
    show('baseline', d)
    assert d['accessibility'], 'Accessibility permission required'
    fixture = subprocess.Popen([str(fixture_app/'Contents/MacOS/TuckFixture')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    fixture_ids = {'local.tuck.fixture::TuckTestAlpha','local.tuck.fixture::TuckTestBeta'}
    d = wait(lambda d: settled(d)
             and fixture_ids.issubset({i['id'] for i in d.get('icons', [])})
             and fixture_ids.issubset(set(json.loads(config.read_text())['visible'])))
    show('late discovery populated', d)
    original = json.loads(config.read_text())
    target = json.loads(json.dumps(original))
    preferred = ['local.tuck.fixture::TuckTestAlpha', 'local.tuck.fixture::TuckTestBeta']
    ids = [x for x in preferred if x in target['visible']][:2]
    assert len(ids)==2, 'Fixture discovery failed'
    target['visible'] = [x for x in target['visible'] if x not in ids]
    target['hidden'] = list(reversed(ids))
    target['showHidden'] = False
    save(target)
    d = wait(lambda d: visible_state(d, False) and d.get('hiddenIDs') == target['hidden'])
    show('hot reload + hide', d)
    # Visibility is part of the document, including external editor saves.
    target['showHidden'] = True
    save(target)
    d = visibility(True)
    show('external reveal', d)
    order = [x['id'] for x in d['icons'] if x['id'] in ids]
    assert order == target['hidden'], (order, target['hidden'])
    assert d['controlX'] > max(x['x'] for x in d['icons'] if x['movable']), 'Control not at right edge'
    target['showHidden'] = False
    save(target)
    show('external hide', visibility(False))
    click()
    show('click persisted reveal', visibility(True))
    # A normal restart must adopt persisted true, not reset an in-memory flag.
    quit_app()
    runtime.unlink(missing_ok=True)
    p = subprocess.Popen([str(ROOT/'.build/debug/Tuck'), '--config', str(config), '--no-prompt'],
                         stdout=log, stderr=subprocess.STDOUT)
    show('restart retained reveal', visibility(True))
    click()
    show('click persisted hide', visibility(False))
    # Invalid content must survive, without losing the last-good layout.
    config.write_text('{ invalid json')
    d = wait(lambda d: d.get('pid') == p.pid and d.get('phase') == 'blocked'
             and d.get('pending') is False and d.get('error') is not None)
    assert config.read_text()=='{ invalid json'
    assert d['hiddenIDs']==target['hidden']
    show('invalid config retained', d)
    assert d.get('showHidden') is False, d
    requested = d['showHidden']
    spacer = d['separatorWidth']
    click()
    # Observe a bounded interval: a rejected toggle must never transiently reveal.
    until = time.monotonic() + 1
    while time.monotonic() < until:
        assert p.poll() is None, 'Tuck exited after rejected toggle'
        current = state()
        assert current.get('pid') == p.pid, current
        assert config.read_text() == '{ invalid json', 'Toggle overwrote invalid config'
        assert current.get('showHidden') is requested, current
        assert current.get('separatorWidth') == spacer, current
        time.sleep(.05)
    show('invalid config toggle refused', state())
    save(target)
    d = visibility(False)
    # No app-generated idle loop. External user/app activity may legitimately
    # cause events, so keep the machine quiet during this interval.
    before = visibility(False)
    cpu = subprocess.check_output(['ps', '-p', str(p.pid), '-o', 'time=']).decode().strip()
    time.sleep(5)
    after = state()
    print('idle: scans', before.get('scans'), after.get('scans'), 'CPU time before', cpu,
          'after', subprocess.check_output(['ps','-p',str(p.pid),'-o','time=,%cpu=,rss=']).decode().strip(), flush=True)
    assert settled(after), after
    assert before['scans']==after['scans'], 'Unexpected idle scans; check external activity'
    save(original)
    d = wait(lambda d: settled(d) and d.get('separatorWidth') == 4
             and d.get('hiddenIDs') == [] and d.get('showHidden') is original.get('showHidden', False))
    show('restored', d)
    print('PASS; evidence:', root, flush=True)
finally:
    try:
        if original:
            save(original)
            if p.poll() is None:
                try:
                    wait(lambda d: settled(d) and d.get('hiddenIDs') == original['hidden']
                         and d.get('showHidden') is original.get('showHidden', False), timeout=10)
                except RuntimeError as error:
                    print('Cleanup restore did not settle:', error, flush=True)
    finally:
        try:
            quit_app()
        except (subprocess.SubprocessError, OSError) as error:
            print('Graceful quit failed; killing isolated test process:', error, flush=True)
            if p.poll() is None:
                p.kill(); p.wait()
        finally:
            log.close()
            if fixture:
                fixture.terminate()
                fixture.wait(timeout=3)
            print('Logs:', root)
