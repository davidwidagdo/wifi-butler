# WiFi Butler menu-bar app

A native macOS menu-bar app that keeps you logged in to a captive-portal WiFi. It has no Dock icon and lives in the
status bar. Built with `swiftc` and `hdiutil`: no Xcode project and no third-party dependencies.

## Features

- **Live speed meter.** Two stacked lines in the menu bar (↓ download, ↑ upload) that switch units on their own
  (B/s, KB/s, MB/s, GB/s), with monospaced digits so the width stays steady. A bolt icon shows the state: filled
  when connected, slashed when logged out or offline, circling arrows while logging in.
- **Daily WiFi usage.** Today's download and upload totals in the menu, plus a **Usage History** window with the last
  30 days, 7- and 30-day summaries and today's peak speeds. It reads the interface's own 64-bit byte counters, so the
  totals match what the system reports.
- **System metrics.** CPU, memory (with Activity Monitor's "used" figure and the kernel's memory-pressure level), free
  disk space and uptime, all in the menu. Hovering **CPU** or **Memory** lists the top three apps, grouped by name so
  a browser's helper processes collapse into one row. CPU and RAM can also show in the menu bar, sharing one column so
  the second costs no extra width. Both are off by default.
- **Menu.** **Login Now**, **Auto-Login**, **Start at Login**, **Show in Menu Bar** (Speed, CPU, RAM),
  **Usage History…**, **Open Activity Monitor**, **Settings…**, **Open Log** and **Quit**.
- **Only logs in where the portal exists.** It finds the portal's own login form on the intercepted captive page and
  submits that. On any other WiFi, or when offline, it stays **Idle** and never posts your credentials. An optional
  **Portal marker** (a word from the portal's login page, such as `hotspot`) also requires the page to match.
- **Settings.** Four tabs: **Login** (username and password, with rarely needed portal fallbacks behind an
  *Advanced* toggle), **Speed Meter** (show or hide, update interval, decimal or binary units, WiFi interface),
  **System** (metrics, CPU and RAM in the menu bar, update interval) and **General** (auto-login, start at login,
  poll interval).
- **Storage.** The password lives in the macOS **Keychain**, the other settings in `UserDefaults`. The log rotates
  itself, so it never grows without bound.
- **Triggers.** It logs in again on **polling** (portal session timeouts, where the WiFi link never drops), **network
  reconnect** (`NWPathMonitor`, for sleep and roaming) and **wake from sleep**. After each login it probes again to
  confirm success.

## Build

```sh
./build.sh
```

This produces `build/WiFi Butler.app` and `build/WiFi-Butler.dmg`.

## Install

1. Open `build/WiFi-Butler.dmg` and drag the app to **Applications**.
2. First launch: the app is only ad-hoc signed, so **right-click**, choose **Open**, then **Open** again to get past
   Gatekeeper. After that it opens normally.
3. Click the menu-bar icon, choose **Settings…**, fill in your credentials and **Save**.
4. Turn on **Start at Login** so it runs automatically.

## Notes

- **Editing credentials.** Everything changes from **Settings…**; there are no config files to touch.
- **HTTP portals.** The app allows plain-HTTP requests (`NSAllowsArbitraryLoads`) because captive portals and Apple's
  probe use HTTP.
- **After a rebuild or reinstall.** The ad-hoc signature changes with each build, so macOS may ask once to allow
  Keychain access (choose **Always Allow**), and the **Start at Login** registration can be lost: toggle it again
  from the menu.
- **Sharing with others.** Ad-hoc signing works on your own Mac. The build targets macOS 26.0 or later on Apple
  Silicon. To share it without the Gatekeeper warning, sign and notarize it with an Apple Developer account; for
  Intel Macs, also build an `x86_64` slice and `lipo` a universal binary.
- **MikroTik CHAP portals.** If the portal hashes the password with an MD5 challenge (a `challenge` or `chap-id`
  field, see `../discover-portal.sh`), the login needs a small extension; the app currently sends a plain POST.
