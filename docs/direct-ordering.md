# Why Tuck drags the icons of other apps

Tuck positions its own two items directly. It moves every other icon with a
synthetic Command-drag. This page records the experiment behind that split.

The experiment ran on macOS 15.8.2 (24H232). It asked one question. Can a
normal app reorder the status icons of other apps without simulated input,
code injection, an app restart, or root?

The answer is no. A direct path works only for icons that the calling process
owns.

## Icons that Tuck owns

AppKit backs each `NSStatusItem` with an `NSCGSStatusItem`, which the
`_cgsItem` property holds. Its `setPreferredPosition:` and `rebuildStatusBar`
methods moved test icons without mouse events. Tuck uses these two methods for
its separator and its control, and then verifies the new order.

Call these methods from a function that is marked `@MainActor`. An unmarked
async function can run off the main thread even when a main-actor task calls
it.

## Icons that other apps own

SkyLight exports two functions that look suitable:

- `SLSTransactionSystemStatusBarSetLayoutIndex(transaction, windowID, index)`
- `SLSTransactionSystemStatusBarResetLayout(transaction, windowIDs)`

A probe app called both functions on the two windows of a test app. The windows
did not move, even though the probe had Accessibility. The same calls from the
test app itself did move its windows.

The disassembly of the server explains the difference. The handler calls
`PKGTransactionCheckWindowAccess(connection, windowID, 4, 0, 0)`. That check
passes for the connection that owns the window or for a holder that the owner
delegated. Accessibility is not part of the check. When the check fails, the
server skips the change and still reports success.

The experiment did not try to get privileged rights, inject code, disable SIP,
or act as the connection of another app.

## Two traps

- Do not read the return value of `SLSTransactionCommit` as an error code. On
  this macOS version the value is not an error code. Verify the real window
  order.
- Accessibility cannot move an icon. `AXPosition`, `AXFrame`, and `AXSize` were
  not settable on the test icon. Its only action was `AXPress`.

## What Tuck does as a result

- Tuck positions its own two items directly and never drags them.
- Tuck moves the icons of other apps with a Command-drag in `Mover.swift`. The
  planner and the config do not know about the drag.
- Tuck verifies the real order after every move.
- Both paths use private interfaces, so a macOS update can break either.

The probe code and a sample transcript are in `scripts/research/`.
