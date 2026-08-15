# Power Benchmark Plan

MacVigil should not market itself as more power efficient than another keep-awake utility until the difference is measured under equivalent conditions.

This document defines a repeatable way to test that claim.

## What we want to learn

1. How much energy does MacVigil itself consume while idle?
2. How much extra energy is caused by keeping the system awake for a real workload?
3. How much does display/backlight policy change battery drain?
4. Does closed-lid handling add measurable overhead?
5. How does MacVigil compare with `caffeinate` and an equivalent Amphetamine configuration?
6. How much energy is saved when job-aware protection ends immediately after the job finishes instead of using a fixed timer?

## Important rule

A comparison is valid only when the protected workload and visible-display behavior are equivalent.

It is not meaningful to compare:

- MacVigil with the display dark

against

- another tool configured to keep the display bright.

That would measure the configuration difference rather than application overhead.

## Test systems

Every published result should include:

- Mac model
- SoC/CPU
- RAM
- battery cycle count / maximum capacity if available
- macOS version and build
- MacVigil version/commit
- competitor version
- power source
- room/environment notes if thermal behavior matters

## Suggested test matrix

### A. Utility overhead, no heavy workload

Configurations:

1. macOS baseline, machine intentionally kept active
2. `caffeinate -i`
3. Amphetamine — system awake, display allowed to sleep
4. MacVigil Compute Guard — display allowed to sleep

Measure app CPU/memory and whole-system energy.

### B. Developer workload

Use the exact same deterministic build/test command for every run.

Examples:

```sh
swift build -c release
```

or a fixed repository test suite.

Compare:

- `caffeinate`
- Amphetamine equivalent
- MacVigil

### C. Local AI workload

Use a fixed local-model prompt/evaluation workload with the same model and inference parameters.

Record:

- total job duration
- battery change
- approximate average power if available
- thermal state
- whether the display was visible/dark/asleep

### D. Long-running server

Run an idle local HTTP service or model server for 60–120 minutes.

This tests utility/background overhead more clearly than a CPU-heavy workload where the workload itself dominates energy consumption.

### E. Closed-lid experiment

Only on hardware/macOS combinations where experimental closed-lid mode is verified.

Compare equivalent headless configurations:

- Amphetamine closed-display mode
- MacVigil Closed-Lid Eco

Record physical lid state, display/backlight behavior, battery drain, thermal state, and any real sleep/wake events.

## Measurement layers

Use more than one measurement when possible.

### Battery delta

Simple and user-relevant:

```text
Start: 80%
End:   72%
Time:  60 min
```

Battery percentage is coarse, so longer runs and repeated tests are preferable.

### macOS `powermetrics`

Where available and appropriate, `powermetrics` can provide whole-system and subsystem data. It usually requires administrator privileges.

The exact fields vary by hardware/macOS release, so raw output should be retained with each benchmark.

### Process CPU/time

Record the keep-awake utility's own CPU utilization and elapsed CPU time. A menu-bar app should remain close to idle when no state transition or diagnostic collection is happening.

### Thermal state

Record whether the system spent meaningful time in:

- nominal
- fair
- serious
- critical

### Sleep/wake evidence

Use:

```sh
pmset -g assertions
pmset -g log
```

A black display must not be confused with system sleep.

## Controlling variables

Before a benchmark:

- use the same display brightness when the screen is visible
- use the same Wi-Fi network
- disconnect unnecessary peripherals
- stop background downloads/sync where possible
- use the same app set
- wait for the machine to return to a stable thermal state
- avoid Spotlight/indexing or OS-update activity
- use the same battery charge window
- do not compare runs where one system is charging

## Repetition

One run is anecdotal.

For meaningful public results, perform at least 3 runs per configuration and report:

- individual results
- mean
- range

Do not hide outliers; explain them if a background process or thermal event affected a run.

## Example results table

Do not fill this table with estimates. Only publish measured values.

| Scenario | Tool/config | Duration | Battery delta | Avg system power | Utility CPU | Thermal | Notes |
|---|---|---:|---:|---:|---:|---|---|
| Idle server | macOS baseline | TBD | TBD | TBD | n/a | TBD | |
| Idle server | caffeinate | TBD | TBD | TBD | TBD | TBD | |
| Idle server | Amphetamine equivalent | TBD | TBD | TBD | TBD | TBD | |
| Idle server | MacVigil Compute Guard | TBD | TBD | TBD | TBD | TBD | |
| Closed-lid server | Amphetamine | TBD | TBD | TBD | TBD | TBD | |
| Closed-lid server | MacVigil Closed-Lid Eco | TBD | TBD | TBD | TBD | TBD | |

## The benchmark that may matter most

The largest practical saving may come from **ending protection at the right time**.

Example:

- user starts a 4-hour timer for a build
- build actually finishes after 42 minutes
- ordinary timed keep-awake tool remains active for another 3h 18m
- future MacVigil process/command session releases immediately at 42 minutes

That is a real product-level energy optimization even if both applications have negligible idle CPU overhead.

A future benchmark should explicitly measure this scenario.

## Publishing results

When results exist, publish:

- exact methodology
- raw measurements where practical
- hardware/software versions
- equivalent settings for every compared tool
- limitations

Avoid language such as “2× more efficient” unless the underlying measurement supports that exact claim across the stated scenario.

## Success criteria

MacVigil's power-efficiency work is successful if it can demonstrate one or more of the following without sacrificing job reliability:

- lower display-related power for unattended compute
- lower utility overhead
- earlier release of keep-awake state when work completes
- safer battery reserve behavior
- thermal-aware closed-lid handling
- clearer energy/runtime visibility for the user
