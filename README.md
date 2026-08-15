<div align="center">

# MacVigil

### Local work, uninterrupted.

**Keep AI agents, local models, builds, dev servers, renders, transfers, and long-running jobs working when you step away.**

[![Latest Release](https://img.shields.io/github/v/release/LotfyAymanElnaggar/KeepAwakeMac?display_name=tag&sort=semver)](https://github.com/LotfyAymanElnaggar/KeepAwakeMac/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://github.com/LotfyAymanElnaggar/KeepAwakeMac/releases/latest)
[![Universal](https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-blue)](https://github.com/LotfyAymanElnaggar/KeepAwakeMac/releases/latest)
[![License](https://img.shields.io/github/license/LotfyAymanElnaggar/KeepAwakeMac)](LICENSE)

[Download](https://github.com/LotfyAymanElnaggar/KeepAwakeMac/releases/latest) · [Roadmap](ROADMAP.md) · [Power efficiency](docs/POWER-EFFICIENCY.md) · [Use cases](docs/USE-CASES.md) · [Architecture](docs/ARCHITECTURE.md) · [Troubleshooting](docs/TROUBLESHOOTING.md)

</div>

> **Naming transition:** MacVigil is the product name being developed for this project. Current app bundles, release assets, paths, and diagnostics may still say **KeepAwakeMac** while the rebrand is completed safely.

---

## Why MacVigil exists

A Mac is no longer only an interactive desktop. It can be a local AI workstation, coding-agent host, Docker machine, build server, inference endpoint, render node, remote development box, or temporary home-lab server.

Those workloads often need one simple guarantee:

> **The job should keep running even when the human stops touching the computer.**

Traditional keep-awake tools solve the basic sleep problem. MacVigil's direction is more specific: **protect the runtime while wasting as little power as practical on things the workload does not need.**

That means treating these as separate concerns:

- keeping the CPU/system available,
- keeping networking and storage work alive,
- deciding whether the display should remain visible,
- handling MacBook lid closure,
- respecting battery and thermal safety,
- and eventually ending protection when the actual job finishes.

## Power-first philosophy

**Keeping the Mac awake should not automatically mean keeping the screen bright.**

MacVigil is being designed around explicit runtime states:

| Mode | Computer | Built-in display | Best for |
|---|---|---|---|
| **Full Awake** | Awake | Kept awake | presentations, monitoring, demos |
| **Compute Guard** | Awake | May sleep normally | AI agents, builds, servers, downloads |
| **Closed-Lid Runtime** | Awake | Built-in backlight darkened when possible | headless/local compute on a MacBook |

Current v1.3 closed-lid darkening saves the built-in display brightness and sets the **backlight brightness to 0**. That is intentionally different from claiming the entire display panel consumes zero power. A future goal is to measure and, where macOS allows it safely, reduce display power further without unintentionally locking or sleeping the user session.

See [Power Efficiency](docs/POWER-EFFICIENCY.md) and the planned [Power Benchmarks](docs/POWER-BENCHMARKS.md).

## Built for modern local development

MacVigil is especially useful when you leave work running locally:

```text
AI agent / build / server / transfer starts
                  ↓
            Vigil becomes active
                  ↓
        You stop using the keyboard
                  ↓
       Display may go dark to save power
                  ↓
        Compute + network stay available
                  ↓
             Job finishes
                  ↓
     Future: Vigil ends automatically
```

Examples include:

- AI coding agents implementing, testing, or refactoring a repository
- Ollama, LM Studio, MLX, llama.cpp, and other local-model runtimes
- Xcode, Swift, Rust, C/C++, Node, Python, and Android builds
- Docker / Docker Compose / local Kubernetes workloads
- local web APIs, databases, MCP servers, and development servers
- SSH, Tailscale, remote desktop, and remote development
- long downloads, uploads, Git operations, backups, and sync jobs
- Blender/video/audio rendering and batch exports
- data science, notebooks, simulations, ETL, embeddings, and batch inference

A broader catalog is in [Use Cases](docs/USE-CASES.md).

## What works today — v1.3

### Runtime protection

- 15 min, 30 min, 1 h, 2 h, custom, or indefinite sessions
- IOKit `PreventSystemSleep` assertion
- IOKit `PreventUserIdleSystemSleep` assertion
- Foundation `idleSystemSleepDisabled` activity
- active veto of ordinary idle-sleep requests while a session is running
- optional display-awake assertion when the display must stay visible

### Experimental MacBook closed-lid runtime

On the macOS 27 beta test machine, `pmset -a disablesleep 1` alone was not enough: the kernel still reported `AppleClamshellCausesSleep = Yes` and recorded `Clamshell Sleep`.

v1.3 therefore combines:

1. verified system-wide `SleepDisabled=1`, and
2. the internal IOPM root-domain clamshell sleep guard used by macOS itself.

The kernel guard is reinforced during lid/power transitions and by a companion watchdog.

### Display/backlight behavior

When **Allow display to go dark** is enabled and the MacBook lid closes without an external display:

- the app saves the built-in brightness,
- sets the built-in backlight brightness to 0,
- keeps the runtime protected,
- and restores brightness when the lid reopens or the session ends.

This avoids deliberately invoking `pmset displaysleepnow` for closed-lid darkening, because full display sleep can interact with the user's normal lock/password policy.

### Safety

- configurable 10%, 15%, 20%, or 25% low-battery cutoff
- crash/heartbeat watchdog
- ownership tracking before restoring global `SleepDisabled`
- diagnostics showing assertions, battery, lid state, kernel guard state, and recent sleep/wake logs
- no password storage
- narrow sudo authorization limited to two exact `pmset` commands

See [SECURITY.md](SECURITY.md).

## Install

Download the newest DMG from:

**https://github.com/LotfyAymanElnaggar/KeepAwakeMac/releases/latest**

Current builds are universal for Apple Silicon and Intel and target macOS 13+.

### Gatekeeper note

The current experimental build is **ad-hoc signed**, not yet Developer ID notarized. On first launch, macOS may require right-click → **Open** or approval under **System Settings → Privacy & Security**.

Proper Developer ID signing and notarization are roadmap priorities before broader public distribution.

## Quick start

1. Launch the app and find the menu-bar icon.
2. Choose a duration.
3. Leave **Allow display to go dark** enabled for compute-only work.
4. Turn the session on.
5. For experimental lid-closed use, install the one-time Lid Authorization and enable **Keep running with lid closed**.
6. Confirm both the `SleepDisabled` and kernel-guard indicators before closing the lid.
7. Use **Copy Diagnostics** if the Mac behaves unexpectedly.

For detailed operation and recovery instructions, see [Troubleshooting](docs/TROUBLESHOOTING.md).

## Where MacVigil is going

The next major step is **job-aware, energy-aware runtime protection**.

High-priority planned features include:

- thermal safety using macOS thermal-pressure state
- measured energy profiles and repeatable benchmarks
- battery-energy budgets, not only percentage cutoffs
- process/PID-based sessions
- command-based sessions: keep awake until a command exits
- local-port/server detection
- Docker/container-aware sessions
- AI-agent and local-model runtime presets
- **Finish → restore normal sleep** workflows
- notifications when unattended jobs complete or protection is stopped for safety
- a small CLI for terminal-native workflows
- Shortcuts/automation integration
- Developer ID signing + notarization
- Homebrew Cask distribution

The full public plan is in [ROADMAP.md](ROADMAP.md).

## A note on comparisons

General-purpose tools such as Amphetamine already provide strong keep-awake automation, display-sleep controls, closed-display features, and battery conditions. MacVigil should not claim to consume less power merely because its positioning is power-focused.

**The goal is to earn that claim with measurements.**

The project will benchmark equivalent workloads and runtime states on the same hardware, publish the methodology, and optimize from measured results. See [Power Benchmarks](docs/POWER-BENCHMARKS.md).

## Documentation

| Document | Purpose |
|---|---|
| [ROADMAP.md](ROADMAP.md) | planned features and product direction |
| [Power Efficiency](docs/POWER-EFFICIENCY.md) | energy philosophy, modes, and technical goals |
| [Power Benchmarks](docs/POWER-BENCHMARKS.md) | repeatable measurement methodology |
| [Use Cases](docs/USE-CASES.md) | AI, development, creative, research, server, and transfer scenarios |
| [Architecture](docs/ARCHITECTURE.md) | current power-management design and cleanup model |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | diagnostics, recovery, and common failure modes |
| [SECURITY.md](SECURITY.md) | privilege and watchdog security model |
| [CONTRIBUTING.md](CONTRIBUTING.md) | how to contribute safely |

## Safety

Closed-lid runtime means the Mac can continue producing heat after the lid is shut.

**Never use closed-lid mode in a bag, sleeve, drawer, or other poorly ventilated space.**

Battery and thermal safety must always take precedence over keeping a job alive. The app intentionally does not attempt to override critical-battery, thermal-emergency, shutdown, or other mandatory macOS safety behavior.

## Privacy

MacVigil is intended to work locally. The current app does not require an account and does not need your macOS password beyond the standard system administrator authorization dialog used to install the narrowly scoped lid-mode rule.

## Contributing

Issues, hardware test reports, power measurements, and code contributions are welcome. Power-management changes can leave a machine unable to sleep if cleanup is wrong, so please read [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md) before changing lid or privilege code.

## License

MIT — see [LICENSE](LICENSE).
