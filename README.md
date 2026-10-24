# Omarchy WalkingPad

Control a KingSmith **WalkingPad** over Bluetooth from the Omarchy bar.
Tested on the **R1 Pro**. Other WalkingPads that use the same Bluetooth
protocol (service `FE00`: A1 / A1 Pro, R1, C1) should work too, since the
plugin finds pads by that protocol, not by model name. Newer models that use the
standard fitness-machine (FTMS) profile aren't supported yet.

- Bar icon shows your speed (or steps) while walking
- Popup: start/stop, speed slider and ±, Manual / Auto / Standby mode,
  session stats, today's totals and a 7-day step chart
- Keyboard and scroll control, plus IPC commands for Hyprland keybindings
- Daily totals are kept in `~/.local/state/omarchy-walkingpad/history.json` (last 30 days)

## Requirements

- BlueZ (`bluez`, `bluez-utils`) with the adapter powered on
- `python-dbus-fast` (already present on Omarchy). The bridge runs with
  `/usr/bin/python3` on purpose, so a mise/pyenv Python on your `PATH`
  doesn't hide the system package.

No pairing is needed. On first run the plugin scans for the pad, then
remembers its address in `~/.local/state/omarchy-walkingpad/device.json`.

## Install

```bash
omarchy plugin add https://github.com/kristijanzrno/omarchy-walkingpad.git --enable
```

## Using it

| Where | Input | Action |
|---|---|---|
| Bar | left click | open popup |
| Bar | right click | start / stop belt |
| Bar | middle click | connect / disconnect |
| Bar | scroll | faster / slower (while walking) |
| Popup | `space` / `s` / `enter` | start / stop belt |
| Popup | `←` `→` / `-` `+` | slower / faster |
| Popup | `m` | cycle Manual → Auto → Standby |
| Popup | `c` | connect / disconnect |

When starting, the pad switches itself to Manual mode, counts down 3 seconds,
then the plugin sets the **Speed after starting** (default 2.0 km/h).

**The phone app:** a WalkingPad accepts one Bluetooth connection at a time. To
use the KS Fit app, flip the switch in the popup header (or middle-click the
icon) to disconnect, or set **Connect automatically** to Off.

## Keybindings

The shared service answers on IPC target `walkingpad`:

```bash
omarchy-shell walkingpad toggle       # start / stop
omarchy-shell walkingpad start
omarchy-shell walkingpad stop
omarchy-shell walkingpad faster
omarchy-shell walkingpad slower
omarchy-shell walkingpad speed 3.5
omarchy-shell walkingpad mode auto    # manual | auto | standby
omarchy-shell walkingpad connect
omarchy-shell walkingpad disconnect
omarchy-shell walkingpad status       # JSON
omarchy-shell io.github.kristijanzrno.walkingpad toggle  # open / close the popup
```

For example, in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + W", "WalkingPad start/stop", "omarchy-shell walkingpad toggle")
o.bind("SUPER + ALT + EQUAL", "WalkingPad faster", "omarchy-shell walkingpad faster")
o.bind("SUPER + ALT + MINUS", "WalkingPad slower", "omarchy-shell walkingpad slower")
```

## Settings

Set these in the bar widget's settings, or on its entry in
`~/.config/omarchy/shell.json`:

| Key | Values | Default |
|---|---|---|
| `barLabel` | `speed`, `steps`, `today`, `icon` | `speed` |
| `maxSpeed` | `6.0`, `8.0`, `10.0` (R1 Pro: 6 walking, 10 with the handrail up) | `6.0` |
| `speedStep` | `0.1`, `0.2`, `0.5`, `1.0` | `0.5` |
| `startSpeed` | `keep`, `1.0` … `4.0` | `2.0` |
| `autoConnect` | `on`, `off` | `on` |

## How it works

```
Panel.qml (one per bar) ──reads──▶ Service.qml (one per shell)
                                      │ stdin: commands  ▲ stdout: JSON state
                                      ▼                  │
                                   walkingpad.py ── D-Bus ── BlueZ ── BLE ── pad
```

`walkingpad.py` connects through BlueZ, subscribes to characteristic `FE01`,
and asks for stats once a second by writing to `FE02`. Frames are
`F7 <cmd…> <sum> FD` going out and `F8 A2 …` status frames coming back.
Commands are spaced 0.7 s apart because the pad drops them when sent faster.

Debug the bridge on its own (stop the plugin first, since only one client
can hold the pad):

```bash
/usr/bin/python3 walkingpad.py --verbose
# then type: start 2.5 | speed 3 | stop | mode auto | quit
```

Protocol details come from the
[ph4-walkingpad](https://github.com/ph4r05/ph4-walkingpad) project.
