# Power Efficiency

MacVigil's core product idea is simple:

> **Keep the workload alive without keeping unnecessary hardware active.**

A traditional keep-awake switch answers only one question: should macOS sleep?

MacVigil should eventually answer a more useful set of questions:

- Does the workload still need the CPU?
- Does it still need networking/storage?
- Does the user need to see the screen?
- Is the Mac on battery or external power?
- Is the battery reserve still healthy?
- Is thermal pressure safe?
- Has the protected job already finished?

## Current behavior

v1.3 already separates some of these concerns.

### System runtime

An active session uses multiple sleep-prevention mechanisms so ordinary idle sleep does not interrupt work.

### Display behavior

If the user allows the display to go dark, MacVigil does not create the display-awake assertion. With the lid open, macOS may therefore apply the user's normal display-sleep policy while the system itself remains protected.

For experimental lid-closed mode, v1.3 saves the built-in brightness and sets the built-in **backlight brightness to 0** when the physical lid closes and no external display is connected.

That reduces backlight use, but it is important to be precise:

> **Backlight brightness 0 is not proof that the entire display panel is electrically off.**

The project must not market this as “zero screen power” until measurements demonstrate what the hardware is actually doing.

## Competitive principle

General-purpose utilities such as Amphetamine already support letting the display sleep while the system stays awake, battery conditions, and closed-display operation.

Therefore, MacVigil's useful differentiation is not simply “we can turn the display off too.”

The stronger direction is:

### Energy-aware runtime continuity

MacVigil should protect **only what the job needs**, adapt to battery/thermal conditions, and release protection automatically when the job is complete.

That means the future product should combine:

- workload-aware session lifetime,
- display/backlight policy,
- battery reserve,
- thermal state,
- power-source conditions,
- measured runtime energy,
- and safe completion behavior.

## Planned energy modes

### Compute Guard

Use when the user needs CPU/network/storage but not a visible screen.

Expected behavior:

- prevent system idle sleep,
- permit ordinary display sleep,
- do not generate synthetic mouse activity,
- do not keep the screen saver suppressed unless explicitly requested,
- restore all normal sleep behavior after the protected job ends.

Primary use cases:

- AI agents
- builds/tests
- local servers
- Docker
- model inference
- downloads/uploads
- SSH/remote access
- data processing

### Closed-Lid Eco

Use for experimental headless MacBook workloads.

Expected behavior:

- protect the runtime against lid-triggered sleep where supported,
- minimize built-in display/backlight activity,
- preserve external displays unless the user explicitly asks otherwise,
- enforce stricter battery and thermal safeguards,
- restore normal clamshell behavior immediately when the session ends.

Because closed-lid operation can trap heat, this mode must remain more conservative than open-lid Compute Guard.

### Full Awake

Use when the visible display is part of the workload.

Examples:

- presentation
- kiosk/dashboard
- monitoring screen
- demo
- live recording where the display must not sleep

This mode intentionally consumes more energy and should never be the default for background compute jobs.

## Battery strategy

The current percentage cutoff is only the first safety mechanism.

Planned improvements:

### Reserve-based protection

Instead of merely “stop at 10%,” let the user say:

> Keep 25% battery in reserve.

That frames the feature around what the user wants left after the job.

### Power-source conditions

Examples:

- run indefinitely only while connected to power,
- allow battery sessions for at most N minutes,
- switch from Closed-Lid Eco to normal sleep when power is disconnected.

### Time-to-reserve estimate

Using current discharge information, MacVigil can estimate how long remains before the safety floor is reached.

This should be shown as an estimate, not a guarantee.

### Energy budget

Longer-term concept:

> Allow this unattended job to consume up to approximately 8 Wh, then restore normal sleep behavior.

This requires reliable measurement and should not ship until validated.

## Thermal strategy

Battery is only one safety dimension.

macOS exposes process thermal pressure through `ProcessInfo.thermalState`.

Planned policy:

- `.nominal` — normal operation
- `.fair` — informational
- `.serious` — warning and optionally reduce the aggressiveness of closed-lid operation
- `.critical` — disarm experimental closed-lid mode and restore ordinary system behavior

MacVigil should never attempt to defeat a thermal emergency sleep/shutdown.

## Display strategy

The display is one of the clearest places to avoid unnecessary energy use, but there are several distinct states:

1. **Visible and bright**
2. **Dimmed/backlight 0**
3. **Display asleep/panel power-managed**
4. **System asleep**

These are not equivalent.

A future UI should show the actual state instead of using a single ambiguous “screen off” label.

### Why not always call `pmset displaysleepnow`?

Full display sleep can interact with the user's macOS lock/password policy. For closed-lid v1.3, MacVigil therefore darkens the built-in backlight rather than intentionally starting the display-sleep path.

The longer-term technical goal is to investigate whether the built-in panel can be placed in a lower-power state **without** creating unwanted lock/session side effects and without affecting connected external displays.

## Workload-aware efficiency

The biggest energy savings may come from knowing when protection is no longer needed.

A fixed 4-hour keep-awake session wastes energy if the build finished after 38 minutes.

Future examples:

```text
Keep awake while PID 9123 exists
```

```text
Keep awake while localhost:3000 is listening
```

```text
Keep awake until `npm test` exits
```

```text
Keep awake while container `api-dev` is running
```

When the condition ends, MacVigil can immediately release its assertions and return control to macOS.

That is a stronger power-saving mechanism than merely choosing a lower display brightness.

## Measuring instead of guessing

Any public claim such as:

> “MacVigil uses less battery than Amphetamine”

must be treated as **unproven** until measured under equivalent configurations.

The test must use:

- the same Mac,
- the same macOS build,
- the same battery health,
- the same workload,
- the same network/peripheral conditions,
- equivalent screen/lid states,
- equal test duration,
- and repeated runs.

See [POWER-BENCHMARKS.md](POWER-BENCHMARKS.md).

## Future power UI

A useful long-term status panel could look like:

```text
VIGIL ACTIVE

Protected job       local-agent
Runtime              47m
System               Awake / protected
Display              Dark
Lid guard            Armed
Power source         Battery
Battery              68%
Reserve              25%
Thermal              Nominal
Estimated to reserve 2h 14m
```

The UI should answer both:

1. **Will my job keep running?**
2. **What is MacVigil costing me to keep it running?**

## Non-goals

Power efficiency does not mean MacVigil should silently:

- throttle the user's workload,
- enable macOS Low Power Mode without permission,
- change brightness while the user is actively using the display,
- disable security/lock policies,
- or override mandatory battery/thermal protection.

The user should remain in control of performance-vs-energy tradeoffs.
