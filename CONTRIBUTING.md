# Contributing to MacVigil

Thanks for helping improve MacVigil (currently published from the `KeepAwakeMac` repository and binary name during the rebrand).

This project touches macOS power-management state, including experimental closed-lid behavior. Changes should prioritize **state restoration, safety, and measurable behavior** over cleverness.

## Good contributions

Especially useful areas:

- macOS / Mac model compatibility reports
- power measurements and benchmark results
- sleep/wake log analysis
- battery and thermal safety
- process/command/port trigger design
- developer and AI workflow presets
- UI clarity around display vs system sleep
- tests for `pmset`/`ioreg` parsing
- crash/recovery hardening
- documentation

## Before changing power code

Read:

- [SECURITY.md](SECURITY.md)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/POWER-EFFICIENCY.md](docs/POWER-EFFICIENCY.md)
- [ROADMAP.md](ROADMAP.md)

Important invariants:

1. A normal session must release every IOPM assertion/activity it created.
2. Global `SleepDisabled` must be restored only when MacVigil owns that change.
3. The kernel clamshell guard must have both normal and crash cleanup paths.
4. Saved brightness must be restored after closed-lid darkening.
5. Critical battery/thermal/system safety must not be overridden.
6. External displays must not be blanked unintentionally.
7. Lock/password security settings must not be silently weakened.

## Build

The project intentionally uses a small Swift source layout and GitHub Actions currently builds the universal application directly with `swiftc`.

The CI workflows are in:

```text
.github/workflows/
```

The main Swift sources are in:

```text
KeepAwakeMac/
```

## Testing sleep behavior

When testing a change, do not report only “the screen went black.”

Verify whether the **system actually slept**.

Useful commands:

```sh
pmset -g
pmset -g assertions
pmset -g batt
ioreg -r -k AppleClamshellState -d 4
pmset -g log | tail -n 100
```

For closed-lid work, test only in a well-ventilated environment and preferably on external power during early development.

## Power benchmark contributions

Follow [docs/POWER-BENCHMARKS.md](docs/POWER-BENCHMARKS.md).

Please include hardware/software versions and equivalent display/power settings for every compared tool.

Do not submit benchmark claims based on one run or mismatched display configurations.

## Feature design

New triggers should be separated from power policy.

Preferred mental model:

```text
activation/completion condition → Vigil session → power policy
```

For example, a future Docker trigger should not independently manipulate IOPM assertions. It should create/end a session that reuses the central power-state engine.

## Security-sensitive changes

Do not broaden the sudoers rule without a strong technical reason and explicit review.

Current passwordless commands are intentionally restricted to:

```text
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

Never add shell wildcards or arbitrary executable permission merely for convenience.

Do not log passwords, authentication output, tokens, environment secrets, or unrelated process command lines.

## Internal/private macOS APIs

Current experimental lid/backlight support uses internal macOS mechanisms.

Any new private API use should document:

- why a public API is insufficient
- expected macOS compatibility risk
- failure behavior
- cleanup behavior
- whether it affects Mac App Store eligibility
- how diagnostics will reveal whether the call succeeded

Prefer public APIs for stable/core behavior whenever possible.

## Bug reports

A strong sleep/power bug report includes:

- exact Mac model/chip
- macOS version/build
- app version/commit
- battery vs external power
- external displays/docks
- lid state
- exact reproduction steps
- whether the workload actually stopped
- Copy Diagnostics output
- sleep/wake log around the event

## Product language

Please keep documentation precise.

Prefer:

> “sets the built-in backlight brightness to 0”

instead of:

> “uses zero display power”

unless a benchmark actually proves the latter.

Similarly, do not claim support for a macOS/Mac model combination that has not been tested or verified.

## Pull request scope

Small, focused changes are easier to validate for power-management software.

If a change modifies closed-lid behavior, include the expected state transition and cleanup path in the PR description.

## License

By contributing, you agree that your contribution will be distributed under the repository's MIT License.
