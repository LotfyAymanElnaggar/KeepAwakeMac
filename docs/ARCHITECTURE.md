# Architecture

This document describes the current v1.3 architecture. MacVigil is the planned product name; current source paths and binaries still use **KeepAwakeMac** during the rebrand.

## High-level design

```text
MenuBarExtra / SwiftUI UI
          ↓
      AwakeManager
          ├── IOKit power assertions
          ├── Foundation activity token
          ├── SystemPowerVeto
          ├── pmset SleepDisabled control
          ├── IOPM root-domain clamshell guard
          ├── lid/display state monitoring
          ├── built-in backlight control
          ├── battery safety
          └── watchdog heartbeat
                     ↓
              KeepAwakeLidWatchdog
```

The app deliberately uses multiple independent layers because macOS distinguishes ordinary idle sleep, forced/demand sleep, lid/clamshell policy, display power, and security/lock policy.

## Main components

### `KeepAwakeMacApp.swift`

Application entry point.

- creates the shared `AwakeManager`
- exposes the app through `MenuBarExtra`
- uses a menu-bar-only UI (`LSUIElement`)

### `AwakeMenuView.swift`

SwiftUI menu UI.

Responsibilities include:

- start/stop session
- duration selection
- display policy
- experimental lid-mode controls
- battery cutoff
- authorization install/remove
- diagnostics copy
- lock-settings shortcut

### `AwakeManager.swift`

Owns runtime state and most power-management behavior.

Key responsibilities:

- IOPM assertions
- Foundation activity lifecycle
- global `SleepDisabled` ownership/readback
- kernel clamshell guard
- physical lid monitoring
- external-display detection
- built-in brightness save/restore
- safety timers
- watchdog token lifecycle
- diagnostic collection

### `SystemPowerVeto.swift`

Registers for macOS system-power notifications.

During an active session, ordinary idle-sleep requests may be cancelled. Mandatory/forced power transitions still have to be acknowledged; MacVigil is not intended to defeat thermal emergencies, critical battery handling, shutdown, or other mandatory safety transitions.

### `LidWatchdog.swift`

Small companion executable packaged inside the app bundle.

It exists because closed-lid mode changes state outside the ordinary lifetime of a single SwiftUI view.

If the GUI process dies or stops refreshing its heartbeat, the watchdog attempts to restore:

- kernel clamshell policy
- `SleepDisabled=0` when MacVigil owned that setting
- saved built-in brightness

The helper does not receive the user's password and relies only on the same narrow sudo authorization documented in [../SECURITY.md](../SECURITY.md).

## Runtime protection layers

### 1. `PreventSystemSleep`

A broad IOKit power assertion used while a session is active.

### 2. `PreventUserIdleSystemSleep`

Prevents ordinary user-idle system sleep.

### 3. Foundation activity token

Uses `ProcessInfo.ActivityOptions.idleSystemSleepDisabled`.

When the user chooses to keep the display visible, the activity can also include display-sleep prevention.

### 4. Idle-sleep veto

`SystemPowerVeto` handles ordinary system-power sleep queries and rejects user-idle sleep while the session is active.

This is an extra layer; it is not used to reject mandatory power events.

## Closed-lid architecture

Closed-lid mode is experimental and intentionally separate from the ordinary session.

### `pmset disablesleep`

The app can install a narrowly scoped sudoers rule allowing only:

```text
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

When lid mode is enabled, the app verifies the current state with `pmset -g` and records whether it owns the change.

Ownership matters because `SleepDisabled` is a global system setting, not a per-process reference count.

### Kernel clamshell guard

Real macOS 27 beta diagnostics showed this state at the same time:

```text
SleepDisabled = Yes
AppleClamshellCausesSleep = Yes
Last Sleep Reason = Clamshell Sleep
```

Therefore v1.3 also uses the internal IOPM root-domain user-client clamshell control (`kPMSetClamshellSleepState`, selector 12).

The guard is reinforced during lid/wake transitions because beta power policy can be reevaluated.

This is an internal/undocumented mechanism and may stop working on future macOS releases.

## Display/backlight architecture

### Open lid

If display sleep is allowed, MacVigil avoids holding a display-awake assertion. The user's normal macOS display timing can therefore apply while the system runtime remains protected.

### Closed lid

For the current experimental closed-lid path, MacVigil:

1. detects `AppleClamshellState`
2. checks for external displays with Core Graphics
3. saves built-in brightness
4. sets built-in backlight brightness to 0 using DisplayServices
5. restores brightness after lid-open/disarm

This is a backlight-darkening strategy, not a guarantee that the whole panel has entered its lowest electrical power state.

## External display protection

MacVigil checks online displays through Core Graphics.

Current design principle:

> Never blank or modify an external display as a side effect of trying to save power on the built-in MacBook panel.

Future display-power work should preserve that rule unless the user explicitly opts into multi-display control.

## Safety architecture

### Battery cutoff

While experimental lid mode is active on battery power, the app periodically reads battery state and disarms the session when the configured floor is reached.

### Thermal guard — planned

The next safety layer should use `ProcessInfo.thermalState` to warn/disarm under serious/critical thermal pressure.

### Watchdog

The GUI periodically touches a heartbeat token. The companion process monitors it and performs best-effort cleanup after an abnormal GUI exit.

## State restoration rules

Every global or user-visible change should have an explicit owner and cleanup path.

Examples:

| State | Ownership | Restore behavior |
|---|---|---|
| IOPM assertion | process-local ID | release assertion |
| Foundation activity | process-local token | end activity |
| `SleepDisabled` | global, ownership marker | set to 0 only if app owns it |
| kernel clamshell guard | global kernel connection state | clear on disarm/crash |
| built-in brightness | saved per session | restore saved value |
| watchdog token | app-created cache file | remove on cleanup |

## Diagnostics

The app intentionally exposes underlying state instead of showing only a green toggle.

Current diagnostics include:

- active session state
- authorization state
- `SleepDisabled` readback
- kernel selector state/return code
- `AppleClamshellCausesSleep`
- physical lid state
- external display detection
- backlight state
- battery/power source
- IOPM assertions
- `pmset -g`
- recent sleep/wake logs

This makes it possible to distinguish:

- display went dark
- display entered sleep
- actual system sleep
- clamshell-forced sleep
- safety cutoff
- assertion failure

## Future architecture direction

The next major architectural change should separate **session reason** from **power policy**.

For example:

```text
Session condition        Power policy
------------------       ------------------
PID exists         ───→  Compute Guard
Port 3000 open     ───→  Compute Guard
Presentation       ───→  Full Awake
Closed-lid agent   ───→  Closed-Lid Eco
```

That allows process/port/container/agent triggers to reuse the same well-tested power-state engine.

A future `VigilSession` model should own:

- activation reason
- completion condition
- power mode
- battery reserve
- thermal policy
- display policy
- end action
- runtime metrics

This is preferable to adding trigger-specific logic directly into `AwakeManager`.
