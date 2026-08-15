# MacVigil Roadmap

MacVigil is evolving from a manual keep-awake utility into an **energy-aware local runtime guard for macOS**.

The roadmap is intentionally ordered around reliability and measurable power behavior before adding broad automation.

Legend: ✅ shipped · 🧪 experimental · 🚧 planned next · 💡 later

## Product principles

1. **Protect the job, not every component.** If a workload needs CPU/network but not a visible screen, the display should be free to darken or sleep.
2. **Measure before claiming.** Power-efficiency claims must be backed by repeatable measurements on the same hardware/workload.
3. **Safety wins.** Battery, thermal, shutdown, and emergency system protections must override convenience.
4. **Restore state cleanly.** Every elevated/global setting must have ownership tracking and crash cleanup.
5. **Developer-native automation.** Eventually users should describe the job, not guess a timer.
6. **Transparent state.** The UI should explain why Vigil is active and what is keeping the Mac awake.

---

## 0. Current foundation — v1.3

- ✅ timed and indefinite sessions
- ✅ system + idle-sleep IOKit assertions
- ✅ Foundation idle-sleep activity
- ✅ ordinary idle-sleep veto while a session is active
- ✅ optional display-awake behavior
- ✅ experimental `SleepDisabled` closed-lid mode
- 🧪 direct kernel clamshell guard for macOS versions that still honor clamshell sleep
- 🧪 built-in backlight darkening on lid close
- ✅ low-battery cutoff
- ✅ crash watchdog and ownership-based cleanup
- ✅ detailed diagnostics and recent sleep/wake logs

### Stabilization work

- 🚧 test v1.3 across more Apple Silicon generations
- 🚧 test on stable macOS releases in addition to macOS 27 beta
- 🚧 record a compatibility matrix by Mac model / macOS version
- 🚧 harden wake/lid transition races
- 🚧 add regression tests for parsing `pmset`/`ioreg` output
- 🚧 show a clear in-app distinction between **display dark**, **display asleep**, and **system asleep**

---

## 1. Power Efficiency — highest priority

This is the main product differentiator.

### Runtime energy modes

- 🚧 **Compute Guard** — keep system/network available while allowing normal display sleep
- 🚧 **Closed-Lid Eco** — keep runtime protected while minimizing built-in display/backlight usage
- 🚧 **Full Awake** — keep both system and display awake only when the use case requires it
- 💡 per-profile defaults for battery vs external power

### Battery intelligence

- ✅ percentage-based low-battery cutoff
- 🚧 optional **start only on external power** condition
- 🚧 configurable **battery reserve**: always leave N% for the user
- 🚧 estimated time-to-cutoff based on current discharge rate
- 💡 session energy budget (for example: stop Vigil after approximately X Wh consumed)
- 💡 notify before safety shutdown rather than stopping without warning

### Thermal safety

- 🚧 observe `ProcessInfo.thermalState`
- 🚧 warning on `.serious`
- 🚧 automatically disarm closed-lid mode on `.critical`
- 🚧 record the thermal reason in diagnostics/history
- 💡 user-selectable conservative/balanced/performance thermal policy

### Display efficiency

- ✅ allow display to go dark while compute remains protected
- 🧪 save/restore built-in brightness and set backlight to 0 for current experimental lid mode
- 🚧 measure the real energy difference between backlight 0 and true display sleep
- 🚧 investigate safe panel power-off that does not unexpectedly sleep/lock the user session
- 🚧 never blank an external monitor unless the user explicitly asks
- 💡 faster display-darkening policy when an unattended job is detected

### Measurement

- 🚧 publish repeatable benchmark protocol
- 🚧 measure MacVigil vs baseline `caffeinate`
- 🚧 measure equivalent MacVigil vs Amphetamine configurations
- 🚧 publish battery-drain and system-power results instead of marketing estimates
- 💡 show session-level estimated energy consumed inside MacVigil

See [docs/POWER-EFFICIENCY.md](docs/POWER-EFFICIENCY.md) and [docs/POWER-BENCHMARKS.md](docs/POWER-BENCHMARKS.md).

---

## 2. Job-aware sessions

The long-term UX should be **“protect this job until it is done”**, not “guess how many hours it needs.”

### Process / command triggers

- 🚧 keep awake while a selected process is running
- 🚧 keep awake while a PID exists
- 🚧 CLI: run a command inside a Vigil session
- 🚧 end Vigil automatically when the command exits
- 🚧 preserve and display the exit code
- 💡 multiple-process AND/OR rules

Example future workflow:

```sh
macvigil run -- npm test
```

or:

```sh
macvigil watch-pid 43127
```

### Local server triggers

- 🚧 keep awake while a TCP port is listening
- 🚧 presets for common dev ports
- 💡 stop only after the port has been inactive for a grace period

Example:

```text
Vigil while localhost:3000 is listening
```

### Container triggers

- 🚧 Docker process/container detection
- 🚧 stay awake while a named container or Compose project is running
- 💡 Podman / local Kubernetes support

### Network / transfer triggers

- 💡 active SSH session
- 💡 active remote-development session
- 💡 sustained transfer/network activity
- 💡 mounted network volume / external drive

---

## 3. AI + local development workflows

AI is a go-to-market focus, not a hard dependency or vendor lock-in.

### Agent sessions

- 🚧 user-configurable AI-agent process presets
- 🚧 generic detection based on process/command rather than brand-specific integrations
- 🚧 “Agent running” runtime status
- 🚧 notify when the watched agent exits
- 💡 keep Vigil active across agent child processes/build/test loops
- 💡 session history: agent runtime, battery used, end reason

### Local model runtimes

- 🚧 presets for local inference servers such as Ollama/LM Studio/MLX/llama.cpp workflows
- 🚧 port/process-based activation for local model APIs
- 💡 distinguish loaded-but-idle model servers from active inference
- 💡 optional idle timeout after no inference traffic

### Developer workflow presets

- 🚧 Build
- 🚧 Test suite
- 🚧 Dev server
- 🚧 Docker stack
- 🚧 Remote access
- 🚧 Download/model fetch
- 🚧 Render/export

Presets should configure runtime protection, display behavior, battery reserve, and completion behavior together.

---

## 4. Completion actions

When a protected job finishes:

- 🚧 **Restore normal sleep**
- 🚧 notify user
- 🚧 restore display/backlight state
- 💡 lock screen
- 💡 run a user-selected Shortcuts action
- 💡 sleep the Mac after an optional grace period
- 💡 shut down only with explicit user opt-in and confirmation

The default should remain conservative: **restore ordinary macOS behavior, do not force sleep/shutdown.**

---

## 5. UI and runtime observability

- 🚧 rebrand app UI from KeepAwakeMac to MacVigil
- 🚧 clearer status language: Vigil active / protected runtime / display state / lid guard
- 🚧 compact runtime dashboard
- 🚧 show why the session is active (manual, PID, port, container, agent, etc.)
- 🚧 display current battery / power source / safety reserve
- 🚧 display thermal state
- 🚧 session end reason
- 💡 session history
- 💡 menu-bar status variants
- 💡 optional estimated energy used this session

---

## 6. CLI and automation

- 🚧 `macvigil` command-line companion
- 🚧 query current Vigil status
- 🚧 start/stop a manual session
- 🚧 command/PID/port sessions
- 🚧 machine-readable JSON status
- 💡 macOS Shortcuts actions
- 💡 AppleScript support
- 💡 URL scheme
- 💡 local-only automation API

---

## 7. Distribution and trust

Before a wider public launch:

- 🚧 complete MacVigil naming/rebrand migration
- 🚧 Apple Developer ID signing
- 🚧 Apple notarization
- 🚧 reproducible release metadata/checksums
- 🚧 Homebrew Cask submission
- 🚧 clear experimental feature flags for private/internal APIs
- 💡 automatic update channel with signed update metadata

Current experimental GitHub releases are ad-hoc signed and may require manual Gatekeeper approval.

---

## 8. Documentation and testing

- ✅ security model
- ✅ power-efficiency design document
- ✅ benchmark methodology
- ✅ use-case catalog
- ✅ architecture overview
- ✅ troubleshooting guide
- 🚧 hardware/macOS compatibility matrix
- 🚧 automated unit tests for parsing/state machines
- 🚧 manual sleep/lid test checklist for releases
- 🚧 contributor test fixture for captured `pmset`/`ioreg` output

---

## Not planned as default behavior

MacVigil should **not** silently:

- disable macOS login/password policy,
- override critical thermal or battery protection,
- keep the display bright when the workload does not need it,
- change Low Power Mode without explicit user intent,
- claim closed-lid support when verification failed,
- or claim lower energy use than another tool without measurements.

---

## Suggested milestones

### v1.4 — Power Safety

Thermal guard, clearer display/system state, compatibility testing, better battery safety.

### v1.5 — Power Metrics

Benchmark tooling/docs, runtime energy telemetry, improved closed-lid efficiency.

### v1.6 — Job-Aware Vigil

Process/PID/command and port-triggered sessions; finish → restore normal sleep.

### v1.7 — AI/Dev Presets

Agent/local-model/dev-server/Docker presets with completion notifications.

### v2.0 — MacVigil

Completed rebrand, CLI, Developer ID signing/notarization, Homebrew distribution, stabilized compatibility story.
