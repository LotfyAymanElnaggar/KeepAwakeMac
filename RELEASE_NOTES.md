# KeepAwakeMac v1.3.0

This release changes the closed-lid implementation after real macOS 27 beta diagnostics showed that `pmset -a disablesleep 1` was **not sufficient by itself** on the tested MacBook.

The important diagnostic combination was:

```text
SleepDisabled = Yes
AppleClamshellCausesSleep = Yes
Last Sleep Reason = Clamshell Sleep
```

KeepAwakeMac's normal IOKit assertions were also present. In other words, macOS accepted `SleepDisabled`, yet the kernel still kept a separate clamshell policy capable of requesting sleep.

## New: direct kernel clamshell guard

v1.3.0 now uses two independent layers while **Keep running with lid closed** is enabled:

1. the existing system-wide `pmset -a disablesleep 1` setting, and
2. the IOPM root-domain user-client clamshell control used internally by macOS (`kPMSetClamshellSleepState`, external method selector 12).

The second layer directly sets the kernel's clamshell-sleep-disable mask rather than relying on the generic `SleepDisabled` setting alone.

The app re-applies this kernel guard:

- when lid mode is armed,
- immediately when a lid-close edge is detected,
- every 5 seconds while lid mode remains armed,
- after a system wake notification, and
- during the periodic safety check.

This is intentionally redundant because macOS 27 is beta software and may reevaluate power policy during display, lid, battery, and wake transitions.

## New: active idle-sleep veto

While any Keep Awake session is active, v1.3.0 also registers with `IORegisterForSystemPower`.

For ordinary `kIOMessageCanSystemSleep` requests, the app actively calls `IOCancelPowerChange` while the session is enabled. This is an additional layer on top of:

- `PreventSystemSleep`,
- `PreventUserIdleSystemSleep`, and
- Foundation's `idleSystemSleepDisabled` activity.

Forced/emergency sleep notifications still have to be acknowledged; this app does not attempt to override thermal emergencies, critical battery protection, shutdown, or other mandatory system safety behavior.

## Screen dark with lid closed: no more `displaysleepnow`

v1.2.0 used:

```sh
pmset displaysleepnow
```

That can enter macOS's normal display-sleep path and therefore can also start the user's display-off/password timer.

v1.3.0 no longer uses that command for lid-close darkening.

Instead, when all of the following are true:

- lid mode is armed,
- the lid is physically closed,
- **Allow display to go dark** is enabled, and
- no external display is online,

KeepAwakeMac saves the built-in display brightness and sets the **built-in backlight brightness to 0** through macOS DisplayServices. The saved brightness is restored when the lid opens or lid mode stops.

This makes the panel visually dark without KeepAwakeMac deliberately initiating display sleep or locking the user session.

With the lid open, the normal macOS display timer is still allowed to turn the screen off when **Allow display to go dark** is enabled. That is separate from system sleep.

## New: crash-safe companion watchdog

The direct kernel clamshell setting is global and must always be cleaned up. The DMG now includes a small companion executable named:

```text
KeepAwakeLidWatchdog
```

It runs only while lid mode is armed. It watches a heartbeat from the GUI app and, if the GUI crashes or disappears, attempts to:

- clear the kernel clamshell override,
- restore `SleepDisabled=0` only when KeepAwakeMac owned that setting,
- restore the saved built-in display brightness, and
- remove temporary watchdog files.

Normal app shutdown performs the same cleanup directly.

## Better diagnostics

**Copy Diagnostics** now adds:

- `Kernel lid guard active`,
- kernel selector status and return code,
- `AppleClamshellCausesSleep` read-back,
- physical lid state,
- external-display detection,
- whether KeepAwakeMac currently dimmed the built-in backlight,
- saved backlight brightness,
- latest idle-sleep veto timestamp,
- latest system-wake notification timestamp, and
- the last 80 lines of `pmset -g log`.

The log is important because a black screen with the lid open is not necessarily system sleep. If `displaysleep` expires while KeepAwakeMac is active, the display may turn off even though the CPU/network continue running. The new diagnostics make actual sleep/wake events easier to distinguish from display-only sleep.

## Administrator permission remains narrow

The sudoers authorization is unchanged. It grants passwordless access only to exactly these two commands:

```text
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

The direct kernel selector and backlight control do not expand the sudoers rule.

## Important compatibility note

The kernel clamshell selector and DisplayServices brightness functions are internal/undocumented macOS mechanisms. v1.3.0 is therefore an experimental GitHub build, especially on macOS 27 beta. Apple may change these mechanisms in future beta or production releases.

KeepAwakeMac verifies and exposes the actual selector return code and power state rather than claiming that lid mode is guaranteed on every Mac/macOS version.

## Safety

Even when the built-in panel is dark, the CPU, GPU, networking, storage and other components may continue running with the lid closed. **Do not put the MacBook in a bag, sleeve, drawer, or other poorly ventilated place while lid mode is armed.**

For testing, use external power when possible and keep the low-battery cutoff at 20% or 25% until behavior on your macOS beta build is confirmed.

If normal system sleep does not return after testing, run:

```sh
sudo pmset -a disablesleep 0
```

Then quit/relaunch KeepAwakeMac so its kernel guard is also released. The app's companion watchdog is designed to handle this automatically after a crash.
