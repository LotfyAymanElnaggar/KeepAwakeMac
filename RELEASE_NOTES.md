# KeepAwakeMac v1.1.1

This patch fixes the menu-bar pop-up on macOS 27 beta. In v1.1.0, SwiftUI could collapse the root `ScrollView` in `MenuBarExtra` window style into a thin horizontal strip because the popover only had a maximum height and no explicit content height.

## Fixed

- **Menu-bar pop-up sizing:** the window now opens at a stable 400 × 620 point content size.
- The settings remain vertically scrollable when the full content does not fit.
- The content stack explicitly fills the pop-up width instead of relying on the `ScrollView`'s ideal size.

## Lid-closed mode included

v1.1.1 retains the v1.1.0 lid-closed implementation:

- `pmset -a disablesleep 1` for verified lid-closed operation in addition to normal IOKit keep-awake assertions.
- One-time administrator authorization limited to exactly `pmset ... disablesleep 1` and `pmset ... disablesleep 0`.
- Read-back verification through `pmset -g`; lid mode is only reported as armed when macOS reports `SleepDisabled = 1`.
- Crash/heartbeat watchdog that attempts to restore `SleepDisabled = 0` if the app disappears while it owns the setting.
- Configurable 10%, 15%, 20%, or 25% low-battery cutoff.
- Copyable diagnostics for `pmset -g`, power assertions, battery state, and app state.
- Universal DMG for Apple Silicon and Intel.

## Important safety note

Lid-closed mode disables normal system sleep globally for the duration of the mode. Do not put the MacBook in a bag, sleeve, drawer, or other poorly ventilated place while it is armed.

## macOS 27 beta

This is a test build for current macOS versions including macOS 27 beta. `disablesleep` is a system power-management setting rather than a normal public app API, so behavior can change between beta builds or hardware revisions. KeepAwakeMac verifies the actual macOS read-back state rather than assuming success.

## Recovery

If normal sleep does not return after a test, run:

```sh
sudo pmset -a disablesleep 0
```

Then verify:

```sh
pmset -g | grep -i SleepDisabled
```

Expected value after restoration: `0`.
