# brightsync

Mirror the built-in display brightness of an Apple Silicon Mac to external
displays over DDC/CI.

Change brightness with the keyboard, Control Center, or let the ambient light
sensor do it - every connected DDC-capable external display follows
immediately. No menu bar app, no polling: the daemon receives the same
notification the system UI uses and pushes the mapped luminance straight to
the display over I2C.

## Install

```sh
brew install pszypowicz/tap/brightsync
brew services start brightsync
```

`brew services` registers it as a login launch agent. Run `brightsync
--verbose` in a terminal instead if you want to watch it work.

## Usage

```
brightsync                     run in the foreground
brightsync --list              show displays and current values, then exit
brightsync --once              sync once and exit
brightsync --set-external 40   write luminance percent (0-100) to all
                               external displays and exit; the next
                               brightness change re-syncs over it
brightsync --help              all flags
```

## Configuration

Flags or `~/.config/brightsync/config.json` (flags win). The service reads
the file at startup; restart it after editing
(`brew services restart brightsync`).

```json
{
  "min": 10,
  "max": 100,
  "gamma": 1.4,
  "intervalMs": 50
}
```

- `min` / `max` - external luminance range (0-100) mapped to internal
  brightness 0..1. Raise `min` if the external display gets too dark at the
  low end.
- `gamma` - curve exponent applied to the internal brightness before mapping.
  Values above 1 keep the external display dimmer in the midrange; below 1
  keep it brighter.
- `intervalMs` - minimum gap between DDC writes. Brightness changes arrive in
  bursts (macOS ramps smoothly), so writes are coalesced to the most recent
  value at this rate. Raise it if your display is flaky under rapid DDC
  traffic.

## Requirements and limitations

- Apple Silicon only. The DDC transport used here is the Apple DCP I2C
  service; Intel Macs need a different mechanism (see
  [ddcctl](https://github.com/kfix/ddcctl)).
- The display must have DDC/CI enabled (usually an OSD menu setting, on by
  default on most displays).
- Direct HDMI/DisplayPort/USB-C connections work; DisplayLink docks do not
  pass DDC, and some hubs/KVMs are unreliable.
- Apple displays (Studio Display, Pro Display XDR) are controlled natively by
  macOS and are ignored by this tool.
- All external displays receive the same mapped value.
- Uses private macOS APIs (DisplayServices brightness notifications,
  IOAVService I2C). These have been stable for years and are what the popular
  brightness utilities use, but a macOS update could break them.

## How it works

1. `DisplayServicesRegisterForBrightnessChangeNotifications` (private
   DisplayServices.framework, resolved at runtime) delivers a callback with
   the new built-in brightness whenever it changes, whatever the source.
2. The value is mapped through `min + (max - min) * value^gamma` and scaled to
   the luminance range the display reports.
3. `IOAVServiceWriteI2C` (IOKit) writes the DDC/CI luminance VCP (0x10) to
   every `DCPAVServiceProxy` IORegistry entry located `External`.
4. Display hotplug, sleep/wake, and clamshell transitions trigger a debounced
   re-discovery and re-sync.

## Acknowledgments

The DDC/CI-over-DCP technique comes from
[m1ddc](https://github.com/waydabber/m1ddc), and the DisplayServices
notification approach from
[MonitorControl](https://github.com/MonitorControl/MonitorControl) and
[Lunar](https://github.com/alin23/Lunar). If you want a GUI and per-display
control, use those excellent apps instead.

## License

MIT
