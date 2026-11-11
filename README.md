# Tuck

Tuck hides the menu bar icons you choose behind one chevron. A JSON file sets
which icons hide and the order of all of them. Tuck has no dependencies, no
network access, no login item, and no polling.

Tuck runs on macOS 13 or later. It was tested on macOS 15.8.2, Apple silicon.

## Use Tuck

- Left-click the chevron to reveal the hidden icons. Click again to hide them.
- Right-click the chevron to open the config or to quit.
- Grant Accessibility in System Settings, Privacy & Security. Tuck asks for no
  other permission.

The chevron sits at the right edge of the icons that Tuck manages. You cannot
move it.

## Edit the config

Tuck creates `~/.config/tuck/config.json` and adds each icon that it finds.

```json
{
	"version": 1,
	"showHidden": false,
	"visible": ["hex"],
	"hidden": ["drive"],
	"items": {
		"hex": { "bundleID": "anomaly.hex", "label": "Hex", "movable": true },
		"drive": { "bundleID": "com.google.drivefs", "label": "Google Drive", "movable": true }
	}
}
```

- `visible` and `hidden` list icon IDs from left to right. To move an icon,
  change its position in a list. To hide or show an icon, move its ID to the
  other list.
- `showHidden` is the only visibility state. The chevron toggles it in the
  file. You can also set it from an editor or a script.
- Every ID in `items` must appear exactly once in `visible` or `hidden`.
- You can rename an ID if you rename every reference to it. You can edit
  `label`. Do not edit `bundleID` or `item`, because they identify the icon.
- `movable` is a description. You cannot make a fixed system icon movable.
- `__tuck_separator__` and `__tuck_control__` are reserved IDs.

Tuck watches the file and applies each valid save without a restart. If a save
is invalid, Tuck keeps the last valid layout and shows the error in the
chevron's tooltip. If you delete the entry of a running icon, Tuck adds the
entry again.

Use a regular file, not a symlink. Tuck does not write through a symlink.

## Build and install

You need a Swift 6 toolchain.

```sh
./build.sh              # builds build/Tuck.app
./build.sh --install    # copies it to ~/Applications/Tuck.app; quit Tuck first
open ~/Applications/Tuck.app
```

`build.sh` signs with the local development identity in
`~/.local/share/tuck/signing/` when that identity exists. Set
`TUCK_SIGN_IDENTITY` to use a different identity. Without either, the build is
ad-hoc signed, and macOS can ask for Accessibility approval again after each
rebuild. Do not regenerate the local identity. A new certificate with the same
name does not keep the approval.

The build is local. It is not notarized.

## Test

```sh
swift test
.build/debug/Tuck --inventory
.build/debug/Tuck --validate ~/.config/tuck/config.json
```

`--inventory` prints the icons that Tuck can see. `--validate` checks a config
file.

The scripts in `scripts/` drive the real menu bar. Quit Tuck before you run
one, run it from a terminal that has Accessibility, and keep the pointer still.

| Script | What it checks |
| --- | --- |
| `integration.py` | Ordering, hot reload, click to reveal and hide, recovery from an invalid config |
| `resilience.py` | Behavior while another app does not answer Accessibility calls |
| `bench-reconcile.py` | Time for one full reconcile pass, for two or more builds |
| `benchmark-visibility.py` | Time from a click to hidden icons |

## Read the diagnostics

`~/.config/tuck/runtime.json` records what Tuck last did. The useful fields are:

- `phase`: `idle`, `observing`, `applying`, `waiting`, `waiting-input`,
  `blocked`, or `suspended`.
- `error` and `waiting`: the reason that Tuck is not `idle`.
- `revision` and `appliedRevision`: the config revision that you asked for and
  the revision that Tuck applied. They are equal when Tuck is done.
- `icons`: each icon that Tuck found, with its position.
- `reconcileMS`: the time of the last full pass. `reconcilePhases` splits it
  into `windows` (the window-list read), `apps` (Accessibility reads),
  `register` (config writes), and `apply` (moves and the separator).
- `verifiedLayout`: `true` when Tuck can trust its picture of the menu bar
  without asking any app again.
- `auditMismatches`: how often a background check found that picture wrong.
  It should stay at 0.

If System Settings shows Accessibility as enabled but `accessibility` is
`false`, run `tccutil reset Accessibility local.tuck` and approve Tuck again.
The command affects only Tuck. Do not reset every app.

## Limits

- macOS has no public API to move the icons of other apps. Tuck moves them with
  a synthetic Command-drag and then checks the new order. A drag moves the
  pointer for about half a second.
- If a drag fails twice, Tuck leaves the order as it is and still hides and
  reveals. The tooltip names the icon that did not move.
- Tuck does not move icons while a menu is open, while you hold a mouse button
  or a modifier key, or while the screen is locked.
- The clock, Control Centre, and the privacy indicators stay where macOS puts
  them.
- Tuck leaves an icon alone when it cannot tell the icon from another icon of
  the same app.
- An icon behind the notch cannot be dragged. Tuck drags its copy on a wider
  attached display when there is one.
- Tuck reads window titles and positions its own two items through private
  macOS interfaces. A macOS update can break either. Tuck is not suitable for
  the Mac App Store.

## Learn the design

- [How Tuck stays responsive under load](docs/load-resilience.md)
- [Why Tuck drags the icons of other apps](docs/direct-ordering.md)

| File | Role |
| --- | --- |
| `TuckCore/Configuration`, `ConfigStore`, `ConfigWatcher` | The config model, atomic reads and writes, and the file watcher |
| `TuckCore/MenuRows` | The window list as menu bar rows, one per display |
| `TuckCore/MenuBar` | Which icon each window is, and which apps must be read again |
| `TuckCore/Verdict` | `assess`, the pure function that decides each pass, and the move history |
| `TuckCore/LatestWork`, `Recovery` | Scheduling and retry policy |
| `Tuck/Pass` | One pass: read, assess, act, repeat |
| `Tuck/AppReader`, `AXRead` | Accessibility reads with timeouts and budgets |
| `Tuck/Mover` | The Command-drag |
| `Tuck/Observers`, `MenuRecovery` | Accessibility notifications and open-menu tracking |
| `Tuck/App` | Config adoption, scheduling, and event wiring |
