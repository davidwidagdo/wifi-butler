# WiFi Butler — menu-bar app

A native macOS menu-bar app that keeps you logged in to a captive-portal WiFi.
No Dock icon; it lives in the status bar. Built with `swiftc` + `hdiutil` — no
Xcode project, no third-party dependencies.

## Features

- **Live speed meter** in the menu bar — two stacked lines (↓ download /
  ↑ upload) with automatic unit switching (`B/s → KB/s → MB/s → GB/s`) and
  monospaced digits so the width stays steady. A bolt icon shows connection
  state: filled when connected, slashed when logged out / offline, a spinner
  while logging in.
- **Daily WiFi usage** — today's download/upload totals in the menu, plus a
  **Usage History** window with the last 30 days, 7-/30-day summaries and today's
  peak speeds. It reads the interface's own 64-bit byte counters, so totals match
  what the system reports.
- **System metrics** — CPU, memory (with Activity Monitor's own "used" figure and
  the kernel's memory-pressure level), free disk space and uptime, all in the
  menu. Hovering **CPU** or **Memory** lists the top three apps by usage, grouped
  by name so a browser's helper swarm collapses into one row. CPU and RAM can
  also be shown in the menu bar itself — they share one column, so enabling the
  second costs no extra width. Both are off by default.
- Menu: **Login Now**, **Auto-Login**, **Start at Login**, **Show in Menu Bar**
  (Speed / CPU / RAM), **Usage History…**, **Open Activity Monitor**,
  **Settings…**, **Open Log**, **Quit**.
- **Only logs in where the portal exists.** It auto-detects the portal's own
  login form on the intercepted captive page and submits that; on any other WiFi,
  or when offline, it stays **Idle** and never POSTs your credentials. Set an
  optional **Portal marker** (a word from the portal's login page, e.g. `hotspot`)
  to also require the page matches — a safety belt against a foreign device.
- **Settings** — four tabs: **Login** (username/password; rarely-needed portal
  fallbacks tucked behind an *Advanced* toggle), **Speed Meter** (show/hide,
  update interval, decimal/binary units, Wi-Fi interface), **System** (show
  metrics, CPU/RAM in menu bar, update interval), **General** (auto-login, start
  at login, poll interval). All booleans are checkboxes.
- Password stored in the macOS **Keychain**; other settings in `UserDefaults`.
  The log self-rotates so it can never grow unbounded.
- Re-logs in on three triggers: **polling** (catches portal session timeouts,
  where the WiFi link never drops), **network reconnect** (`NWPathMonitor`, for
  sleep/roaming), and **wake from sleep**. After each login it re-probes to
  confirm success.

## Build

```sh
./build.sh
```

Produces:
- `build/WiFi Butler.app`
- `build/WiFi-Butler.dmg`

## Install

1. Open `build/WiFi-Butler.dmg`, drag the app to **Applications**.
2. First launch (the app is only ad-hoc signed): **right-click → Open → Open**
   to get past Gatekeeper. After that it opens normally.
3. Click the menu-bar icon → **Settings…**, fill in your credentials, **Save**.
4. Enable **Start at Login** so it runs automatically.

## Notes

- **Editing credentials:** everything is changed from **Settings…** — no config
  files to touch.
- **HTTP portals:** the app allows plain-HTTP requests
  (`NSAllowsArbitraryLoads`) because captive portals and Apple's probe use HTTP.
- **After a rebuild/reinstall:** the ad-hoc signature changes each build, so
  (1) macOS may ask once to allow Keychain access — choose **Always Allow**, and
  (2) the **Start at Login** registration can be invalidated — re-toggle it from
  the menu to be sure it still launches at login.
- **Sharing with others:** ad-hoc signing works on your own Mac. The build
  targets macOS 26.0+ (Apple Silicon). To distribute without the Gatekeeper
  warning you'd need to sign + notarize with an Apple Developer account, and to
  run on Intel Macs, build an `x86_64` slice too and `lipo` a universal binary.
- **MikroTik CHAP portals:** if the portal hashes the password with an MD5
  challenge (a `challenge`/`chap-id` field — see `../discover-portal.sh`), the
  login needs a small extension; the current app sends a plain POST.
