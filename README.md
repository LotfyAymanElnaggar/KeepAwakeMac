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

Every push to `main` runs the GitHub Actions workflow in `.github/workflows/build-dmg.yml`. It compiles a universal macOS app (Apple Silicon + Intel), ad-hoc signs it, creates `KeepAwakeMac.dmg`, verifies the disk image, and uploads it as the `KeepAwakeMac-DMG` workflow artifact.

The CI build is not notarized with an Apple Developer ID. On first launch macOS may ask you to confirm the app in Privacy & Security or open it with right-click > Open.

## Important macOS limitation

The app prevents idle sleep. Closing a MacBook lid can still put the computer to sleep, depending on macOS/hardware conditions. The app also does not change your password/lock policy. When a timed session ends, macOS resumes its normal sleep/lock behavior.
