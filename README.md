# KeepAwakeMac

A small native macOS menu-bar utility that keeps your Mac awake for a selected amount of time or indefinitely.

## Features

- Menu-bar only app (no Dock icon)
- Start/stop keep-awake session
- 15 min, 30 min, 1 hour, 2 hours, custom, or indefinite duration
- Option to allow the display to turn off while keeping the Mac awake
- Live countdown for timed sessions
- Quick link to macOS Lock Screen settings

## Downloadable DMG

Every push to `main` runs the GitHub Actions workflow in `.github/workflows/build-dmg.yml`. It builds a Release app and packages `KeepAwakeMac.dmg` as a workflow artifact.

The CI build is ad-hoc signed, not notarized with an Apple Developer ID. On first launch macOS may ask you to confirm the app in Privacy & Security or open it with right-click > Open.

## Run from source

1. Open `KeepAwakeMac.xcodeproj` in Xcode.
2. Select the `KeepAwakeMac` scheme and `My Mac` as the run destination.
3. Press Run (Command-R).
4. Look for the cup icon in the macOS menu bar.

No special entitlement is required for the IOKit power assertion used by this project.

## Important macOS limitation

The app prevents idle sleep. Closing a MacBook lid can still put the computer to sleep, depending on macOS/hardware conditions. The app also does not change your password/lock policy. When a timed session ends, macOS resumes its normal sleep/lock behavior.
