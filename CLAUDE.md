# hdCLEANER — project context

Personal macOS disk cleaner, a take on AppYogi's Disk Cleaner (Pro Disk Cleaner): categories of junk with sizes, sub-list, Rescan / Clean, threshold monitor. Interface: follow the Socle design system.

## Architecture
- `Sources/HdCleanerCore`: no AppKit. `Scanner` (categories, one owner per path, `ScanContext` injected), `Cleaner` + `PathGuard` (last safety check before any deletion), `DiskInfo` / `ThresholdMonitor`, `AppSettings`.
- `Sources/hdCLEANER`: AppKit + SwiftUI window app (`MainView`, `SettingsView`, `About`, `AppModel`). When the monitor is on, closing the window keeps the app alive as a menu bar icon (`MonitorStatus`); at login `LoginAgent` (SMAppService agent, `Resources/LaunchAgent.plist`) starts it with `--monitor`, no window.
- Rules: regenerable categories are deleted (`Disposal.delete`), personal ones go to the Trash (`.trash`), only regenerable ones are preselected, never an item of a running app. Browser data = caches only.
- Leftovers: folder named like a bundle id, vendor not matching any installed/running app, not Apple; never preselected.

## Commands
- Tests: `swift test`. App: `./build.sh` → `~/Applications/Home Applications/hdCLEANER.app`.
- Real checks: `SELFTEST=1 ./build.sh`, then `build/hdCLEANER.app/Contents/MacOS/hdCLEANER --selftest library|e2e <fake home>|trash <file>|render <dir>` (`HDCLEANER_HOME` = fake home for render).
- Languages (fr, en, es, it): `tools/strings_table.py` → `python3 tools/gen_strings.py`. Icon: `assets/make_icon.py`. Logo color ("hd" of the name): violet #A78BFA (`Brand`).

## Open points
- Full Disk Access prompts, notifications and the login agent not tested in the installed app.
- No GitHub `origin` yet.
