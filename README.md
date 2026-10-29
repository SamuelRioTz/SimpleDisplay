<p align="center">
  <img src="branding/assets/logo-512.png" width="128" alt="SimpleDisplay icon">
</p>

<h1 align="center">SimpleDisplay</h1>

<p align="center">
  A lightweight macOS menu bar app for managing displays and creating virtual monitors.
</p>

<p align="center">
  <a href="https://github.com/SamuelRioTz/SimpleDisplay/releases/latest"><img src="https://img.shields.io/github/v/release/SamuelRioTz/SimpleDisplay?sort=semver" alt="Latest Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="License"></a>
  <a href="https://github.com/SamuelRioTz/SimpleDisplay/actions/workflows/build.yml"><img src="https://github.com/SamuelRioTz/SimpleDisplay/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="Platform">
</p>

---

## Features

- **Enable/Disable displays** — turn monitors off for real (they go dark and leave the desktop) and back on, without unplugging them
- **Resolution and zoom** — every row has a resolution menu: Retina "looks like" sizes, native sizes and refresh rates, for physical and virtual displays alike; a virtual display remembers your pick
- **Mirror displays** — mirror a physical display onto the main one with one click, and back; a 15 s countdown protects you from turning off your last visible screen
- **Virtual displays** — create virtual monitors with custom resolutions and device presets (iPhone, iPad, Mac, TV)
- **Set main display** — change your primary monitor from the menu bar
- **HiDPI support** — create Retina virtual displays
- **Sleep/Wake safe** — automatically handles display state across sleep cycles
- **ColorSync fix** — prevents the colorsync deadlock with identical monitors (macOS Sequoia bug) and gives virtual displays a stable identity so they don't leak ICC profiles or keep colorsyncd busy
- **Automation** — `simpledisplay://` URL scheme and `simpledisplayctl` CLI for scripts, Shortcuts, and SSH
- **Lightweight** — lives in the menu bar, under 2 MB to download, no background processes

## Install

### Download

Download the latest DMG from [Releases](https://github.com/SamuelRioTz/SimpleDisplay/releases/latest), open it, and drag SimpleDisplay to Applications.

### First launch

Since v1.6.1 the DMG is signed with a Developer ID and notarized by Apple, so it opens like any other app.

> Older builds (v1.6.0 and before) were only ad-hoc signed and macOS blocks them on first launch: open **System Settings → Privacy & Security**, find the message saying SimpleDisplay was blocked, and click **Open Anyway**. Once is enough.

### Build from source

```bash
git clone https://github.com/SamuelRioTz/SimpleDisplay.git
cd SimpleDisplay
make dmg
open .build/SimpleDisplay.app

# Optional: install the CLI for automation
make cli-install          # /usr/local/bin/simpledisplayctl
```

Requires Xcode Command Line Tools (`xcode-select --install`).

## Automation

SimpleDisplay exposes a `simpledisplay://` URL scheme and a `simpledisplayctl`
CLI so the app can be driven from shell scripts, Shortcuts, SSH, or launchd
agents. The URL scheme activates the app if it is not already running — there
is no separate background process to keep alive.

### URL scheme

| URL                                                                     | Effect                              |
| ----------------------------------------------------------------------- | ----------------------------------- |
| `simpledisplay://open`                                                  | Focus the menu bar.                 |
| `simpledisplay://create?width=N&height=N[&name=S][&refresh=N][&hidpi=true]` | Create a virtual display.           |
| `simpledisplay://remove?id=N` or `?name=S`                              | Remove a virtual display.           |
| `simpledisplay://reconfigure?id=N&width=N&height=N[&refresh=N][&hidpi=true]` | Resize a virtual display in place. |
| `simpledisplay://enable?id=N` or `?name=S`                              | Turn a display back on.             |
| `simpledisplay://disable?id=N` or `?name=S` `[&headless=true]`          | Turn a display off (it goes dark and leaves the desktop). If it is the last visible display, a 15 s countdown turns it back on unless someone clicks **Keep off**; `headless=true` confirms up front. |
| `simpledisplay://mirror?id=N` or `?name=S`                              | Mirror a physical display onto the main display (virtual displays can't be mirror sources, see below). |
| `simpledisplay://unmirror?id=N` or `?name=S`                            | Stop mirroring a display.           |
| `simpledisplay://mode?id=N` or `?name=S` `&width=N&height=N[&hidpi=true][&refresh=N]` | Switch a display (physical or virtual) to one of the modes it offers; `hidpi` picks the Retina "looks like" variant, omitted keeps the current scale and rate. |
| `simpledisplay://status`                                                | Write the display list as JSON to `/tmp/simpledisplay-status.json`. |

Values are validated — dimensions clamp to 100–8192, refresh capped at 240 Hz,
names rejected if they contain control characters — before the app sees them.
Malformed URLs surface as a one-line banner in the menu bar rather than
failing silently.

### CLI

```bash
make cli                  # build .build/apple/Products/Release/simpledisplayctl
make cli-install          # copy to /usr/local/bin (override with CLI_INSTALL_DIR)

simpledisplayctl create --width 2732 --height 2048 --name "iPad Pro" --hidpi
simpledisplayctl remove --name "iPad Pro"
simpledisplayctl reconfigure --id 3 --width 1600 --height 1200
simpledisplayctl disable --name "DELL U2723QE"      # off for real; 15 s countdown if it is the last visible display
simpledisplayctl disable --id 2 --headless          # confirm up front (remote sessions, scripts)
simpledisplayctl enable --id 2
simpledisplayctl mirror --name "DELL U2723QE"       # physical display -> mirror of the main display
simpledisplayctl unmirror --name "DELL U2723QE"
simpledisplayctl mode --name "Ultrawide" --width 1720 --height 720 --hidpi   # 2x zoom on a 3440x1440 virtual display
simpledisplayctl open
simpledisplayctl status   # exit 0 = installed, 2 = missing; prints pid if running
```

`simpledisplayctl` is a thin wrapper — every action builds a
`simpledisplay://` URL and hands it to `/usr/bin/open`. Running the CLI from
an SSH session drives the remote Mac's local SimpleDisplay.

### Remote usage (SSH)

```bash
ssh user@mac "simpledisplayctl create --width 2732 --height 2048 --name iPad"
```

For the remote desktop itself, SimpleDisplay pairs best with [Remote Display](https://remotedisplay.app), our free remote desktop for macOS whose virtual monitors resize to your window: SimpleDisplay prepares the displays, Remote Display streams them. Screen Sharing, VNC, Parsec, AnyDesk and TeamViewer work too.

If SimpleDisplay is not installed, `status` reports that before any action
is attempted so callers can offer to install it first.

## How it works

SimpleDisplay uses Apple's private `CGVirtualDisplay` API to create virtual monitors and the private `CGSConfigureDisplayEnabled` API (the same one `displayplacer` uses) to turn physical displays off and on.

**Disabling a display** deactivates it at the window-server level: it goes dark and stops occupying desktop space, but stays connected. macOS drops a disabled display from its display list, so SimpleDisplay remembers its identity and keeps a greyed-out row for it until you turn it back on. The change applies to the current login session only; after a logout or reboot every display comes back, and SimpleDisplay re-applies your choice when it launches.

**Turning off your last visible display** (only virtual displays would remain) is allowed, because a remote session on a virtual display may want exactly that, but it is guarded: a banner counts down 15 seconds and turns the display back on unless you click **Keep off**. Only a confirmed choice is re-applied on the next launch; if the app quits mid-countdown, it brings the display back when it starts again.

**Mirroring a display** is a separate action (the mirror button next to each physical display's toggle): the display stays on and shows a copy of the main display via `CGConfigureDisplayMirrorOfDisplay`. Mirrors are re-applied on launch and dissolved before sleep to avoid a wake freeze. Only physical displays can be mirrored: making a virtual display the mirror of anything crashes the macOS window server (verified on macOS 26, see `docs/real-disable-vm`), so the app refuses it. Mirroring a physical display onto a virtual one works and is the remote desktop use case.

**Virtual displays** appear as real monitors to macOS — useful for screen sharing specific resolutions, testing responsive layouts, or keeping apps running on a "hidden" screen.

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel

## Known limitations

- Uses private Apple APIs — **cannot be distributed on the Mac App Store**
- Virtual display refresh rate is supported up to 240 Hz (the old 60 Hz limit was an app-side clamp, not a `CGVirtualDisplay` limitation). The private API keeps working far higher — ~488 Hz is the observed ceiling on an M1 Mac mini — so the supported range goes to 240 Hz here.
- Display identification uses names, so two identical monitors may not be distinguishable in all scenarios
- The `CGVirtualDisplay` and `CGSConfigureDisplayEnabled` APIs are undocumented and may change or be removed in future macOS versions

## Contact

Questions, bug reports and ideas: [info@simpledisplay.app](mailto:info@simpledisplay.app), or open an [issue](https://github.com/SamuelRioTz/SimpleDisplay/issues).

## Support

SimpleDisplay is free and open source. If it saves you time, you can [buy me a coffee on Ko-fi](https://ko-fi.com/samuelriotz). It helps cover the Apple developer account and the hardware used for testing.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for build instructions and guidelines.

## License

[GPL-3.0](LICENSE)

## Acknowledgments

Built with insights from the macOS display management community, including [BetterDisplay](https://github.com/waydabber/BetterDisplay), [DeskPad](https://github.com/Stengo/DeskPad), and [displayplacer](https://github.com/jakehilborn/displayplacer).
