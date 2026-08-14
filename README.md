# KeepAwakeMac

A native macOS menu-bar utility for keeping a Mac awake for a selected duration or indefinitely, with an optional **lid-closed mode** for MacBooks.

## Download

**Latest release:** https://github.com/LotfyAymanElnaggar/KeepAwakeMac/releases/latest

The downloadable DMG is a universal build for Apple Silicon and Intel Macs.

> The current test build is ad-hoc signed, not notarized with an Apple Developer ID. On first launch macOS may require right-click > **Open**, or approval in **System Settings > Privacy & Security**.

## Features

- Menu-bar only app; no Dock icon
- Keep-awake sessions for 15 minutes, 30 minutes, 1 hour, 2 hours, custom time, or indefinitely
- Let the display turn off while the Mac itself remains awake
- Optional MacBook lid-closed mode
- Runtime verification that macOS reports `SleepDisabled = 1` before lid mode is considered armed
- One-time, narrowly scoped administrator authorization
- Automatic cleanup when a session ends or the app quits
- Crash/heartbeat watchdog that attempts to restore normal sleep if the app disappears while it owns `SleepDisabled`
- Configurable low-battery safety cutoff (10%, 15%, 20%, or 25%)
- Copyable `pmset` diagnostics for troubleshooting

## Why lid-closed mode is different

Normal macOS power assertions (the same family used by `caffeinate`) prevent ordinary idle sleep, but lid closure is a separate system sleep request. For lid-closed mode, KeepAwakeMac additionally uses the system-wide power-management setting:

```sh
pmset -a disablesleep 1
```

When the mode ends, the app restores:

```sh
pmset -a disablesleep 0
```

`disablesleep` is not a normal public app API, so behavior can vary by Mac model and macOS release, especially beta releases. KeepAwakeMac does not assume the command succeeded: it reads `pmset -g` back and only reports lid mode as armed when `SleepDisabled` is actually enabled.

## One-time administrator authorization

`pmset -a ...` requires administrator privileges. KeepAwakeMac can install a sudoers rule at:

```text
/etc/sudoers.d/keepawakemac
```

The rule is intentionally limited to exactly these two commands:

```text
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

It does **not** grant the app unrestricted sudo access. The app validates the sudoers file with `visudo` before installing it. You can remove the authorization from the app at any time.

See [SECURITY.md](SECURITY.md) for the exact security model.

## How to test lid-closed mode

1. Install and launch KeepAwakeMac.
2. Start a Keep Awake session.
3. Under **MacBook lid**, click **Install Lid Authorization…** and approve the one-time administrator prompt.
4. Enable **Keep running with lid closed**.
5. Confirm the menu shows `SleepDisabled = 1`.
6. Close the lid and test the workload you need to keep running.
7. Reopen the lid and turn the session off when finished.

For a simple test, start a long-running network transfer, local server, timer, or SSH session before closing the lid and verify it continues from another device.

## Display-off versus lock-screen behavior

Keeping the computer awake and requiring authentication after the display turns off are separate macOS settings.

If you want the internal display to turn off and then reopen the lid without a password prompt, review:

**System Settings > Lock Screen > Require password after screen saver begins or display is turned off**

KeepAwakeMac provides a shortcut to that settings page, but it deliberately does not change or store your login password.

## Safety

**Do not use lid-closed mode while the MacBook is in a bag, sleeve, drawer, or other poorly ventilated space.** With system sleep disabled, background workloads can continue producing heat after the lid is closed.

The app therefore includes:

- a low-battery cutoff (15% by default),
- timed sessions,
- a crash/heartbeat watchdog,
- read-back verification of `SleepDisabled`, and
- automatic restoration of normal sleep when a session stops.

Avoid running another app that also changes `pmset disablesleep` at the same time because this setting is global rather than reference-counted.

## Emergency restore

If you ever suspect sleep is still disabled after the app has stopped, run this in Terminal:

```sh
sudo pmset -a disablesleep 0
```

Then verify:

```sh
pmset -g | grep -i SleepDisabled
```

A value of `0` means normal system sleep is restored. During an armed lid-closed session, the app expects a value of `1`.

Useful diagnostics:

```sh
pmset -g
pmset -g assertions
pmset -g batt
```

The app's **Copy Diagnostics** button collects the same information without including your password.

## macOS 27 beta

KeepAwakeMac v1.1.0 is designed to test the `SleepDisabled` approach on current macOS releases, including macOS 27 beta. Because macOS 27 is pre-release software, lid behavior may still vary with hardware, firmware, battery state, thermal state, and beta changes. The in-app read-back check makes failures visible instead of silently pretending lid mode is active.

## Build from source

The project is intentionally small. GitHub Actions compiles the Swift sources directly into a universal macOS app and packages a DMG.

Source files are in `KeepAwakeMac/` and release automation is under `.github/workflows/`.

## License

MIT. See [LICENSE](LICENSE).
