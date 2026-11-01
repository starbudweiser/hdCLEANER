# hdCLEANER — project context

Personal macOS disk cleaner, a take on AppYogi's Disk Cleaner (Pro Disk Cleaner): categories of junk with sizes, sub-list, Rescan / Clean, threshold monitor. Interface: follow the Socle design system.

## Architecture
- `Sources/HdCleanerCore`: no AppKit. `Scanner` (categories, one owner per path, `ScanContext` injected), `Cleaner` + `PathGuard` (last safety check before any deletion), `DiskInfo` / `ThresholdMonitor`, `AppSettings`.
- `Sources/hdCLEANER`: AppKit + SwiftUI window app (`MainView`, `SettingsView`, `About`, `AppModel`). When the monitor is on, closing the window keeps the app alive as a menu bar icon (`MonitorStatus`); at login `LoginAgent` (SMAppService agent, `Resources/LaunchAgent.plist`) starts it with `--monitor`, no window.
- Rules: regenerable categories are deleted (`Disposal.delete`), personal ones go to the Trash (`.trash`), system ones (`.admin`: `/Library/Caches`, `/Library/Logs`, `/var/log` rotated files, macOS installers, `.lproj` of third-party apps) and Time Machine snapshots (`.snapshot`, `tmutil`) go through ONE administrator-password script per cleaning (`AdminScript` → `AdminRunner`, osascript). Only regenerable, password-free categories are preselected, never an item of a running app. Browser data = caches only.
- `PathGuard` has three checks (`isSafe` home, `isSafeAdmin` system places, `isSafeAppBundle` uninstall); note Foundation normalises `/private/var` to `/var`, so system paths use `/var/log`. Tests inject `ScanContext.systemRoot` (never scan the real `/` in tests).
- Uninstaller (`Uninstaller`, "Applications" tab): app + related Library files by bundle id (and name when ≥ 5 letters), all to the Trash; app list loads names first, sizes progressively.
- Leftovers: folder named like a bundle id, vendor not matching any installed/running app, not Apple; never preselected.

## Commands
- Tests: `swift test`. App: `./build.sh` → `~/Applications/Home Applications/hdCLEANER.app`.
- Real checks: `SELFTEST=1 ./build.sh`, then `build/hdCLEANER.app/Contents/MacOS/hdCLEANER --selftest library|apps <name>|e2e <fake home>|trash <file>|render <dir>` (`HDCLEANER_HOME` = fake home, also for launching the GUI; `HDCLEANER_QUIET=1` keeps the window behind, no focus; drive it with computer-use `app_*`).
- Languages (fr, en, es, it): `tools/strings_table.py` → `python3 tools/gen_strings.py`. Icon: `assets/make_icon.py`. Logo color ("hd" of the name): violet #A78BFA (`Brand`).

## Open points
- Administrator-password cleaning (osascript dialog), Full Disk Access prompts, notifications, the login agent and a real uninstall are not tested in the installed app. Real mouse clicks on the category checkboxes could not be synthesised in the background (AXPress works).
- No GitHub `origin` yet.
