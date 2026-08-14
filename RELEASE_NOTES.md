# KeepAwakeMac v1.2.0

This release solves the next macOS 27 closed-lid problem observed in real testing: the Mac successfully stayed awake with `SleepDisabled = 1`, but the built-in display could remain illuminated behind the closed lid and waste battery.

## New: closed-lid display power management

KeepAwakeMac now treats **computer sleep** and **display sleep** as two separate jobs.

When all of these are true:

- a Keep Awake session is active,
- **Keep running with lid closed** is enabled,
- `SleepDisabled = 1` is verified,
- **Allow display to turn off** is enabled,
- the physical MacBook lid is closed, and
- no external display is connected,

KeepAwakeMac runs:

```sh
/usr/bin/pmset displaysleepnow
```

This powers down the display while the computer continues running under lid-closed mode.

## Physical lid detection

The app now checks macOS's `AppleClamshellState` through `ioreg` once per second. The menu and Diagnostics report whether the physical lid is open or closed.

On the open → closed transition, the display-sleep request is sent immediately. While the lid remains closed, KeepAwakeMac periodically sends the request again so a macOS/background event that wakes the panel does not leave it illuminated for the rest of the session.

## External-display protection

`pmset displaysleepnow` sleeps active displays rather than targeting only one display. To avoid blanking a monitor during a desktop/clamshell setup, KeepAwakeMac uses Core Graphics to check whether a non-built-in display is online.

If an external display is detected, automatic lid-close display sleep is skipped and the status is shown in the menu and Diagnostics.

## No new administrator privilege

The existing sudo authorization remains limited to exactly:

```text
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

Display-only sleep is requested separately with `pmset displaysleepnow`; the sudoers rule is not widened.

## Diagnostics additions

**Copy Diagnostics** now includes:

- physical lid closed/open state,
- external display detection,
- display-sleep preference,
- latest display-sleep action/status,
- raw `AppleClamshellState` output,
- existing `SleepDisabled`, assertion, battery, and sudo diagnostics.

## What the v1.1.2 diagnostics proved

The supplied test showed:

- `SleepDisabled = 1`,
- lid mode enabled,
- KeepAwakeMac owned the sleep-disabled state,
- normal sleep prevented,
- the workload continued with the lid closed.

That means the lid-awake mechanism was working. v1.2.0 specifically addresses the remaining illuminated-display/battery-drain problem.

## Lock-screen note

Display power and authentication remain separate macOS policies. `pmset displaysleepnow` may start the normal macOS display-off password timer. If you want reopening the lid not to require authentication, configure **System Settings > Lock Screen > Require password after screen saver begins or display is turned off** according to your security preference.

KeepAwakeMac does not disable authentication or store your password.

## Safety

Even with the screen powered down, the CPU, networking and other hardware may continue running while the lid is closed. Do not put the MacBook in a bag, sleeve, drawer, or poorly ventilated location while `SleepDisabled = 1`.

The low-battery cutoff remains active. If normal sleep ever fails to return, run:

```sh
sudo pmset -a disablesleep 0
```

and verify:

```sh
pmset -g | grep -i SleepDisabled
```

Expected value after restoration: `0`.
