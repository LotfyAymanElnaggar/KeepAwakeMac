# KeepAwakeMac

A native macOS menu-bar utility for keeping a Mac awake for a selected duration or indefinitely, with an experimental **lid-closed mode** for MacBooks.

## Download

**Latest release:** https://github.com/LotfyAymanElnaggar/KeepAwakeMac/releases/latest

The downloadable DMG is a universal Apple Silicon + Intel build.

> GitHub test builds are ad-hoc signed rather than notarized with an Apple Developer ID. On first launch macOS may require right-click > **Open**, or approval under **System Settings > Privacy & Security**.

## Features

- Menu-bar only app; no Dock icon
- 15 min, 30 min, 1 hour, 2 hours, custom, or indefinite keep-awake sessions
- Multiple ordinary keep-awake layers: IOKit assertions, Foundation activity, and an active idle-sleep veto
- Optional MacBook lid mode
- Lid mode combines `pmset SleepDisabled` with a direct IOPM root-domain kernel clamshell guard
- Physical lid monitoring and kernel-policy re-application during macOS 27 beta power transitions
- Closed-lid built-in backlight brightness 0 without intentionally invoking display sleep/lock
- Automatic brightness restoration when the lid opens or the session stops
- External-display detection; built-in backlight override is skipped when an external display is online
- Bundled crash-safety helper that restores lid policy, owned `SleepDisabled`, and saved brightness if the GUI disappears
- Low-battery cutoff (10%, 15%, 20%, or 25%)
- Detailed power, lid, assertion, backlight, and recent sleep/wake diagnostics

## Why lid-closed mode needs a separate kernel guard

Normal IOKit power assertions are designed to prevent ordinary idle sleep. macOS treats physical lid closure through a separate clamshell policy.

On macOS 27 beta, real diagnostics from the test Mac showed all of the following at once:

```text
SleepDisabled = Yes
AppleClamshellCausesSleep = Yes
Last Sleep Reason = Clamshell Sleep
```

That means `pmset -a disablesleep 1` was accepted, yet a separate kernel lid policy still considered clamshell sleep valid.

KeepAwakeMac v1.3 therefore uses **two layers** while lid mode is armed:

```sh
pmset -a disablesleep 1
```

plus the IOPM root-domain user-client clamshell method used by macOS internally (`kPMSetClamshellSleepState`, external selector 12). The direct kernel layer sets the clamshell-sleep-disable mask that participates in the kernel's lid sleep decision.

The app re-applies this guard on lid transitions, after wake, and periodically while lid mode remains armed because macOS 27 is beta software and can reevaluate power state dynamically.

When lid mode stops, KeepAwakeMac clears its kernel guard and, only if it owns the global pmset setting, restores:

```sh
pmset -a disablesleep 0
```

## Ordinary open-lid keep-awake sessions

When the main Keep Awake switch is on, the app combines:

- `PreventSystemSleep`,
- `PreventUserIdleSystemSleep`,
- Foundation `idleSystemSleepDisabled`, and
- `IORegisterForSystemPower` cancellation of ordinary `kIOMessageCanSystemSleep` requests.

If **Allow display to go dark** is enabled, macOS is still allowed to switch the display off while those mechanisms keep the computer itself awake. A black display is therefore not by itself evidence that the Mac entered system sleep.

Forced or emergency sleep remains under macOS control. KeepAwakeMac does not attempt to override shutdown, critical battery protection, thermal emergencies, or other mandatory system safety behavior.

## Closed lid: dark panel without deliberately locking the session

Earlier builds used `pmset displaysleepnow` after lid closure. That enters macOS's display-sleep path and can start the user's normal password-after-display-off timer.

v1.3 no longer uses `displaysleepnow` for lid-close darkening.

When lid mode is armed, **Allow display to go dark** is enabled, the physical lid is closed, and there is no external monitor, KeepAwakeMac:

1. saves the built-in display's current brightness,
2. sets the built-in backlight brightness to `0`, and
3. restores the saved brightness when the lid opens or lid mode stops.

This uses macOS DisplayServices. It makes the internal panel visually dark without KeepAwakeMac deliberately telling macOS to put the display session to sleep.

Display authentication remains a macOS policy. Other events can still lock the session according to your system settings.

## One-time administrator authorization

The direct kernel clamshell control itself does not expand the sudo rule. Administrator permission is used only for the global `pmset` layer.

KeepAwakeMac can install:

```text
/etc/sudoers.d/keepawakemac
```

with permission limited to exactly:

```text
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

It does **not** grant unrestricted sudo access. The app validates only its own sudoers fragment with `visudo` before installing it. You can remove the authorization from the menu at any time.

See [SECURITY.md](SECURITY.md) for the security model.

## Crash-safety helper

The app bundle includes:

```text
KeepAwakeLidWatchdog
```

This small companion runs only while lid mode is armed. The GUI updates a heartbeat file. If the GUI process crashes or the heartbeat becomes stale, the helper attempts to:

- release the kernel clamshell guard,
- restore `SleepDisabled=0` only when KeepAwakeMac owned it,
- restore saved built-in brightness, and
- clean up temporary state files.

Normal shutdown performs the same cleanup directly.

## How to test lid mode

1. Install and launch KeepAwakeMac.
2. Preferably connect power for the first test.
3. Start an **Indefinite** Keep Awake session.
4. Enable **Allow display to go dark**.
5. Install Lid Authorization if needed.
6. Enable **Keep running with lid closed**.
7. Confirm the menu shows **Kernel guard ON** and `SleepDisabled=1`.
8. Close the lid and verify a remote workload, SSH connection, download, or server continues.
9. Reopen the lid and use **Copy Diagnostics**.

The most useful v1.3 diagnostic fields are:

```text
Kernel lid guard active
Kernel selector status
Kernel selector return
AppleClamshellCausesSleep readback
Backlight dimmed by app
Last idle-sleep veto
Last system wake notification
```

Diagnostics also include the last 80 lines of `pmset -g log`, which helps distinguish true system sleep from display-only sleep.

## Safety

**Do not put a MacBook in a bag, sleeve, drawer, or other poorly ventilated location while lid mode is armed.** A dark screen does not mean the CPU, GPU, Wi-Fi, storage, or other hardware has stopped running.

For beta testing, use external power when possible and consider setting the low-battery cutoff to **20% or 25%**.

Avoid running another utility that modifies `pmset disablesleep` at the same time because the setting is global rather than reference-counted.

## Emergency restore

If you suspect normal sleep did not return after testing:

```sh
sudo pmset -a disablesleep 0
```

Then quit and reopen KeepAwakeMac so its in-process kernel guard is also released. The bundled watchdog is designed to perform equivalent cleanup automatically after an app crash.

Useful manual diagnostics:

```sh
pmset -g
pmset -g assertions
pmset -g batt
pmset -g log
ioreg -r -k AppleClamshellState -d 4
```

## Compatibility / private API note

The kernel clamshell selector and DisplayServices brightness functions used for v1.3 lid behavior are internal/undocumented macOS mechanisms. They are not suitable for an App Store build and may change in future macOS releases or beta builds.

KeepAwakeMac exposes the actual selector return code and power-state diagnostics rather than treating these mechanisms as guaranteed across every Mac and macOS release.

## Build from source

GitHub Actions builds the main Swift menu-bar app plus the watchdog companion for both arm64 and x86_64, combines them into universal binaries, ad-hoc signs the app bundle, verifies it, and packages the DMG.

Source files are under `KeepAwakeMac/`; release automation is under `.github/workflows/`.

## License

MIT. See [LICENSE](LICENSE).
