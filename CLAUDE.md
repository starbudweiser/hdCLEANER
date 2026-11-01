# hdCLEANER — project context

Personal macOS disk cleaner, a take on AppYogi's Disk Cleaner (Pro Disk Cleaner): categories of junk with sizes, sub-list, Rescan / Clean, threshold monitor. Interface: follow the Socle design system.

## Architecture
- `Sources/HdCleanerCore`: no AppKit. `Scanner` (categories, one owner per path, `ScanContext` injected), `Cleaner` + `PathGuard` (last safety check before any deletion), `DiskInfo` / `ThresholdMonitor`, `AppSettings`.
- `Sources/hdCLEANER`: AppKit + SwiftUI window app (`MainView`, `SettingsView`, `About`, `AppModel`). When the monitor is on, closing the window keeps the app alive as a menu bar icon (`MonitorStatus`); at login `LoginAgent` (SMAppService agent, `Resources/LaunchAgent.plist`) starts it with `--monitor`, no window.
- Rules: regenerable categories are deleted (`Disposal.delete`), personal ones go to the Trash (`.trash`), system ones (`.admin`: `/Library/Caches`, `/Library/Logs`, `/var/log` rotated files, macOS installers, `.lproj` of third-party apps) and Time Machine snapshots (`.snapshot`, `tmutil`) go through ONE administrator-password script per cleaning (`AdminScript` → `AdminRunner`, osascript). Only regenerable, password-free categories are preselected, never an item of a running app. Browser data = caches only.
- `PathGuard` has three checks (`isSafe` home, `isSafeAdmin` system places, `isSafeAppBundle` uninstall); note Foundation normalises `/private/var` to `/var`, so system paths use `/var/log`. Tests inject `ScanContext.systemRoot` (never scan the real `/` in tests).
- Uninstaller (`Uninstaller`, "Applications" tab): app + related Library files by bundle id (and name when ≥ 5 letters), all to the Trash; app list loads names first, sizes progressively.
- Tools tabs (`Mode`: maintenance, permissions, invisibles): `MaintenanceTask` (scripts; `needsAdmin` → `AdminRunner.runCapturing`, else `ShellJob` with live output and cancel), `PermissionPlan` (builds a `find -x … -exec chflags/chown/chmod` script; order: clear flags → owner/mode/ACL/xattr → set flags; `PermissionGuard` refuses system trees, `/`, `/Users`, `/Volumes`…; `preview()` counts without changing anything), `InvisibleScanner`/`InvisibleCleaner` (items are re-checked against the roots and their exact names before deletion; volume system folders go through admin) and `InvisibleWatcher` (FSEvents → `cleanReported`, only `.DS_Store`, `._*`, `__MACOSX`). `AppSettings.watchedFolders` keeps the app alive in the menu bar (`keepsRunningWithoutWindow`).
- `TreeWalker` (fts) is used instead of `FileManager.enumerator` because Foundation hides `._*` files. FSEvents reports `/private/tmp/…` while `standardizedFileURL` yields `/tmp/…`: always normalise paths before comparing.
- Leftovers: folder named like a bundle id, vendor not matching any installed/running app, not Apple; never preselected.

## Commands
- Tests: `swift test`. App: `./build.sh` → `~/Applications/Home Applications/hdCLEANER.app`.
- Real checks: `SELFTEST=1 ./build.sh`, then `build/hdCLEANER.app/Contents/MacOS/hdCLEANER --selftest library|apps <name>|e2e <fake home>|exclude <fake home>|watch <dir>|maint <non-admin task>|trash <file>|render <dir>` (`HDCLEANER_HOME` = fake home, also for launching the GUI; `HDCLEANER_QUIET=1` keeps the window behind, no focus; drive it with computer-use `app_*`).
- Languages (fr, en, es, it): `tools/strings_table.py` → `python3 tools/gen_strings.py`. Icon: `assets/make_icon.py`. Logo color ("hd" of the name): violet #A78BFA (`Brand`).

## Open points
- Tested for real by the author (Nov 2026): administrator-password cleaning, category checkboxes, a real uninstall. Tested here: FSEvents watcher, the maintenance runner (verify disk), the permission scripts on temp folders, exclusions through the model.
- Not yet tested for real: admin maintenance tasks (DNS, Spotlight, periodic, resetUserPermissions), applying a permission plan with the admin option, hidden-file cleaning of a real volume, notifications, the login agent, Full Disk Access prompts.
- GitHub: starbudweiser/hdCLEANER (`origin`, `main`).
