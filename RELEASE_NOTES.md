# KeepAwakeMac v1.1.0

This release changes lid-closed behavior substantially. Earlier test builds relied only on normal macOS power assertions, which are not sufficient for the physical MacBook lid-close sleep request.

## New

- **Verified lid-closed mode** using macOS `pmset -a disablesleep 1` in addition to normal IOKit keep-awake assertions.
- **One-time administrator authorization** limited to exactly two commands: `pmset ... disablesleep 1` and `pmset ... disablesleep 0`.
- **Read-back verification**: lid mode is only reported as armed when `pmset -g` reports `SleepDisabled = 1`.
- **Crash/heartbeat watchdog** that attempts to restore `SleepDisabled = 0` if the app disappears while it owns the setting.
- **Low-battery cutoff**, configurable to 10%, 15%, 20%, or 25%.
- **Diagnostics** button that copies `pmset -g`, `pmset -g assertions`, battery state, and app state.
- Clear separation between **keeping the Mac running** and **macOS Lock Screen password behavior**.
- Universal DMG for Apple Silicon and Intel.

## Important safety note

Lid-closed mode disables normal system sleep globally for the duration of the mode. Do not put the MacBook in a bag, sleeve, drawer, or other poorly ventilated place while it is armed.

## macOS 27 beta

This build is intended for testing on current macOS versions including macOS 27 beta. `disablesleep` is a system power-management setting rather than a normal public app API, so behavior can change between beta builds or hardware revisions. The app verifies the actual macOS read-back state and exposes diagnostics rather than assuming success.

## Lock screen

If the Mac keeps running with the lid closed but asks for a password when reopened, that is controlled separately by **System Settings > Lock Screen > Require password after screen saver begins or display is turned off**. KeepAwakeMac does not store your password or silently alter that security policy.

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
