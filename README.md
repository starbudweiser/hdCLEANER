# hdCLEANER

A macOS disk cleaner: it scans the usual places for junk, shows what each category would free, and removes what you tick.

## About

hdCLEANER is a personal take on AppYogi's *Disk Cleaner* — not affiliated with its authors. Made by Starbudweiser & Claude Code (Anthropic), MIT License, © 2026 Starbudweiser. Provided as is, without warranty. The app's own *About hdCLEANER* entry is in the application menu.

## Features

- **15 categories** with their size: app caches, app logs, browser caches (never history, cookies or passwords), developer caches (Xcode, Homebrew, npm, pip…), Trash, Downloads, Mail attachments, large files, uninstalled app leftovers, iPhone/iPad backups, iOS photo cache, Music cache, iOS updates, installer packages, screenshots.
- **Safe by design**: only regenerable data is ticked after a scan; personal files (Downloads, large files, installers, screenshots, backups, leftovers) are never ticked and go to the Trash. A last check refuses anything outside your home folder or any top-level folder. Items of a running app are flagged.
- **Exclusions**: right-click a row to stop suggesting it.
- **Threshold monitor**: a notification when free space drops below a percentage, a menu bar icon that stays after the window is closed, optional start at login.
- Dark, light or system theme; French, English, Spanish and Italian (follows the system language, English otherwise).

Some folders (Mail, Safari…) need *Full Disk Access*; the app says so on the category instead of showing an empty list.

## Build from source

```bash
swift test        # unit tests
./build.sh        # builds, signs and installs hdCLEANER.app
```

`build.sh` signs through a helper script specific to the author's machine; edit `SIGN_TOOL` (or use `SIGN_IDENTITY="<certificate name>" ./build.sh`).

- `Sources/HdCleanerCore` — logic with no UI: scanner, safety guard, cleaner, threshold. Unit-tested.
- `Sources/hdCLEANER` — AppKit/SwiftUI app.
- `Resources/*.lproj`, `tools/strings_table.py` — texts in four languages (`python3 tools/gen_strings.py`).
