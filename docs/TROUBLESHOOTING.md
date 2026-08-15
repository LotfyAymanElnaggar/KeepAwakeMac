# Troubleshooting

This guide is written for the current v1.3 experimental release. MacVigil is the planned product name; current diagnostics and binaries may still say **KeepAwakeMac**.

## First: display dark does not necessarily mean system sleep

A Mac can be in several different states:

1. display visible
2. display dark/asleep while system is still running
3. system in dark wake
4. full system sleep

If the screen goes black, first verify whether the actual workload stopped.

Examples:

- ping/SSH from another machine
- observe a download/server remotely
- check whether a build continued
- inspect `pmset -g log` after reopening

## Copy Diagnostics

Use **Copy Diagnostics** from the menu whenever possible.

The diagnostic block includes:

- session state
- `SleepDisabled`
- kernel clamshell guard state
- lid state
- external display detection
- battery state
- power assertions
- `pmset` settings
- recent sleep/wake history

Do not paste passwords, private tokens, repository secrets, or unrelated sensitive terminal history into a public GitHub issue.

## Useful manual commands

### Current settings

```sh
pmset -g
```

### Power assertions

```sh
pmset -g assertions
```

### Battery

```sh
pmset -g batt
```

### Lid/clamshell state

```sh
ioreg -r -k AppleClamshellState -d 4
```

### Recent sleep/wake history

```sh
pmset -g log | tail -n 100
```

## The app says active, but the Mac slept with the lid open

Check `pmset -g assertions` while the session is active.

Expected KeepAwakeMac/MacVigil-owned assertions should include system/idle sleep prevention.

Then inspect the sleep log:

```sh
pmset -g log | tail -n 100
```

Look for the actual sleep reason and timestamp.

Possible causes include:

- critical battery condition
- thermal/emergency power event
- manual sleep
- shutdown/restart
- assertion creation failure
- beta macOS power-management behavior

A display-only timeout is not evidence of system sleep.

## Lid mode is enabled but the Mac sleeps when closed

Before closing the lid, v1.3 should show successful state for both layers:

- `SleepDisabled = 1`
- kernel lid guard active / selector accepted

Diagnostics should also be inspected for:

```text
AppleClamshellCausesSleep
Last Sleep Reason
Kernel selector return
```

If `SleepDisabled=1` but `AppleClamshellCausesSleep=Yes`, the generic pmset setting alone is not controlling the kernel clamshell policy on that system. v1.3's direct kernel guard is intended to address exactly that condition.

If the kernel selector returns an error, include the exact hexadecimal return value in the issue report.

## Built-in screen remains visibly bright with the lid closed

Current v1.3 behavior uses built-in backlight brightness rather than `pmset displaysleepnow` for closed-lid darkening.

Confirm:

- **Allow display to go dark** is enabled
- no external display is detected
- diagnostics report the physical lid as closed
- diagnostics show whether the app believes it dimmed the backlight

Note: brightness 0 means the backlight is dark; it does not prove every part of the display panel is electrically powered off.

## External monitor unexpectedly goes dark

This is not intended behavior.

Collect diagnostics and report:

- connected display model(s)
- connection type (HDMI/DisplayPort/USB-C/Thunderbolt/dock)
- whether the monitor supplies power
- lid state
- whether **Allow display to go dark** was enabled

Current design intentionally avoids applying closed-lid backlight behavior when a non-built-in display is detected.

## Lid authorization fails

MacVigil installs only:

```text
/etc/sudoers.d/keepawakemac
```

and grants only:

```text
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

Validate the app's own rule:

```sh
sudo visudo -cf /etc/sudoers.d/keepawakemac
```

If another application has a malformed sudoers fragment, MacVigil should not use a global `visudo -c` result to decide whether its own fragment is valid.

See [../SECURITY.md](../SECURITY.md).

## Emergency restore: system refuses to sleep after testing

First stop/quit MacVigil normally if possible.

Then restore the global pmset setting:

```sh
sudo pmset -a disablesleep 0
```

Verify:

```sh
pmset -g | grep -i SleepDisabled
```

Expected value:

```text
SleepDisabled 0
```

If you are recovering from a crashed experimental kernel-guard session, relaunch then quit MacVigil so it can release in-process state. The companion watchdog is also designed to clear that guard if the GUI heartbeat disappears.

## Brightness did not restore after an abnormal exit

Use the keyboard brightness controls or System Settings to restore the built-in display brightness.

Then include diagnostics and the crash circumstances in a bug report so the watchdog/restore path can be improved.

## Mac locks when the display turns off

System sleep prevention and account security are different macOS policies.

macOS may require authentication after display sleep according to the user's Lock Screen settings.

MacVigil does not silently modify this security setting or store the user's password.

Current closed-lid v1.3 darkening uses backlight brightness 0 specifically to avoid deliberately triggering the full display-sleep path, but macOS can still lock for other configured reasons.

## Battery drained further than expected

Keeping the Mac awake means CPU, memory, storage, Wi-Fi, background services, and the protected workload may continue consuming energy even with a dark screen.

Check:

- workload CPU/GPU usage
- battery cutoff setting
- external power state
- thermal state
- whether another keep-awake utility is active
- whether a fixed timer remained active long after the actual job finished

One of the project's highest priorities is job-aware session completion so protection ends immediately when the watched job finishes.

## Mac is hot while closed

Disarm closed-lid mode immediately and open the MacBook.

**Do not use closed-lid runtime in a bag, sleeve, drawer, or poorly ventilated location.**

The roadmap includes thermal-pressure safety that will automatically disarm experimental closed-lid mode under dangerous conditions.

## Another keep-awake app is installed

Avoid running two tools that both change the global `pmset disablesleep` state during closed-lid testing.

Because this setting is system-wide rather than per-process, one app may restore a value the other app expected to remain enabled.

Ordinary per-process power assertions are better behaved, but global clamshell/sleep modifications are easiest to debug when only one utility owns them.

## Reporting a useful bug

Please include:

- Mac model and chip
- macOS version and build
- MacVigil/KeepAwakeMac version
- battery or external power
- lid open/closed
- external displays/docks
- exact steps
- whether the actual workload stopped or only the screen went dark
- full **Copy Diagnostics** output

For sleep bugs, the most useful evidence is the recent `pmset` sleep/wake log around the failure.
