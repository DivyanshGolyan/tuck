# How Tuck stays responsive under load

Tuck depends on other apps. It asks menu bar apps for their icons through
Accessibility, and any of those apps can be slow or stuck. This page
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
- Config adoption does not wait for a pass. A reveal needs only Tuck's own
  separator, so a stuck app cannot delay it.
- One pass runs at a time. New events do not queue. They mark the latest
  request as pending, and an old pass cannot mark a newer request as applied.

## How a pass works

A pass repeats three steps until nothing is left to do.

1. Read the window list once. The window list is the set of on-screen windows
   that macOS reports, and every menu bar icon is one of them. The read needs
   no answer from any other app.
2. Update the menu bar model. The model remembers which icon each window is.
   It keeps that identity between passes, and takes every position from the
   new window list. An app is read through Accessibility only when the model
   cannot vouch for it: the app is new, it restarted, or its windows changed.
3. Decide. One pure function, `assess`, takes the config, the model, and the
   history of earlier moves. It returns what the separator must do and the
   next action, which is to stop, to add new icons to the config, or to make
   one move.

When nothing changed, a pass is one window-list read and no Accessibility
call. A hide that changes only `showHidden` is the same pass, limited to what
it can do without reading an app. There is no separate fast path.

`assess` plans the moves that put each icon on the correct side of the
separator before the moves that only fix the order. An icon that you hid is
never left visible because an unrelated icon would not move.

## How a pass stays bounded

- Each Accessibility read has a 0.35 second timeout. Each app and each pass
  also have a read budget. The budget is checked between reads, because Tuck
  cannot interrupt a read that has started.
- When an app that must be read does not answer, the model is incomplete. An
  incomplete model never hides or reveals anything.
- A pass makes a limited number of moves. The limit is twice the number of
  managed icons, and at least four.
- After each full pass, Tuck reads one remembered app again in the background,
  in rotation. If the app disagrees with the model, Tuck drops what it
  remembered and runs another pass. `auditMismatches` counts these.
- Some apps, such as Control Centre, have no launch date. Tuck identifies such
  an app by its kernel start time, so a reused process ID is still detected.

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

## Measurements

All numbers come from one Mac with ten cores, macOS 15.8.2, and about 23 icons.
The Mac was busy during every run, with load averages between 7 and 120.
Compared builds were run in alternation.

| Path | First build | Now | Samples | Evidence |
| --- | --- | --- | --- | --- |
| Full pass, nothing changed | 289 ms | 7.5 ms | 30 each | `scripts/bench-reconcile.py` |

The row holds medians. It measures the case that the model helps most. A pass
after icons move reads the moved apps again and takes about 150 ms. A hide by
click took 239 ms in the first build. It has not been measured again with
`scripts/benchmark-visibility.py` since the model replaced the fast path.

These measurements do not cover every third-party app or display arrangement.

## Sources

- [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Swift concurrency: Behind the scenes](https://developer.apple.com/videos/play/wwdc2021/10254/)
- [`AXUIElementSetMessagingTimeout`](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout)
- [`AXUIElementPerformAction`](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction)
- [`AXObserverAddNotification`](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification)
