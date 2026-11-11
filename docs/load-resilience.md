# How Tuck stays responsive under load

Tuck depends on other apps. Each scan asks every menu bar app for its icons
through Accessibility, and any of those apps can be slow or stuck. This page
explains how Tuck keeps the chevron responsive when that happens.

The aim is modest. Slow convergence is acceptable. A frozen chevron, a growing
queue, a repeated drag, or a false report of success is not.

## The config is the only desired state

`showHidden` and the two ID lists in the config say what you want. Everything
else is a fact about progress: the observed layout, `phase`, and
`appliedRevision` in `runtime.json`. A retry reads the config again. It never
replays an old click or flips a second flag.

A click writes `showHidden` to the file. The file watcher then applies the new
value, the same way it applies an edit from an editor.

## Where the work runs

- AppKit calls stay on the main actor.
- Accessibility and window-list reads run on one serial worker. Config reads
  and writes run on a second serial worker. The main actor never blocks on
  either.
- Config adoption does not wait for a scan. A reveal needs only Tuck's own
  separator, so a stuck app cannot delay it.
- One pass runs at a time. New events do not queue. They mark the latest
  request as pending, and an old pass cannot mark a newer request as applied.

## How a scan stays bounded

- Each Accessibility read has a 0.35 second timeout. Each app and each scan
  also have a read budget. The budget is checked between reads, because Tuck
  cannot interrupt a read that has started.
- When an app does not answer, Tuck keeps the last icons that it read from that
  app and marks the scan incomplete. An incomplete scan never hides or reveals
  anything.
- A scan asks an app for icon geometry only when the app's status windows
  changed since its last clean read. One remembered app is read again on every
  scan, in rotation, to notice a switch of the active display. Tuck forgets
  every remembered app when the icons report more than one menu bar row.
- Some apps, such as Control Centre, have no launch date. Tuck identifies such
  an app by its kernel start time, so the remembered icons survive a scan and
  a reused process ID is still detected.

## What Tuck does after a failure

| Result | What Tuck does |
| --- | --- |
| An app is busy or times out | Retries the read later |
| An element reference is stale | Drops it, finds the element again, and retries |
| An attribute is unsupported | Treats the attribute as absent. Does not retry |
| Accessibility is not granted | Waits for you to grant it |
| The config is invalid | Keeps the file and the last valid layout. Waits for an edit |
| The config lock is busy | Retries against the latest file |
| A drag has no visible effect | Reads the order three times, then tries once more |
| A second drag has no effect | Keeps the order and still applies visibility |

Retries share one timer. The delays are 0.25, 0.75, 2, 5, 15, and then 30
seconds. The timer exists only while work is pending. An idle Tuck schedules
nothing.

Tuck never repeats a drag because a read timed out. A drag whose result is
unknown is checked first.

## The fast hide

A hide that changes only `showHidden` skips the scan. Tuck reads the window
list once and compares it with the last layout that a full pass verified. If
the windows and their order match, Tuck hides at once. If anything differs,
Tuck runs a full pass.

## Measurements

All numbers come from one Mac with ten cores, macOS 15.8.2, and about 23 icons.
The Mac was busy during every run, with load averages between 7 and 120.
Compared builds were run in alternation.

| Path | Before | After | Samples | Evidence |
| --- | --- | --- | --- | --- |
| Hide by click, fast path | 239 ms | 36 ms | 5 each | `scripts/benchmark-visibility.py` |
| Full pass, nothing changed | 204 ms | 39 ms | 36 each | `scripts/bench-reconcile.py` |

Both rows are medians. The full-pass row measures the case that the remembered
icons help most. A pass after icons move reads the moved apps again and is
slower.

These measurements do not cover every third-party app or display arrangement.

## Sources

- [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Swift concurrency: Behind the scenes](https://developer.apple.com/videos/play/wwdc2021/10254/)
- [`AXUIElementSetMessagingTimeout`](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout)
- [`AXUIElementPerformAction`](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction)
- [`AXObserverAddNotification`](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification)
