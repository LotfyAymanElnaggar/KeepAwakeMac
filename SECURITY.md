# Security model

KeepAwakeMac's ordinary open-lid keep-awake mode does not require administrator privileges.

Lid-closed mode combines an internal IOPM kernel clamshell guard with the system-wide macOS `pmset disablesleep` setting. Only the `pmset` part requires root privileges.

## What the one-time authorization installs

When you click **Install Lid Authorization…**, macOS shows its standard administrator authentication dialog. KeepAwakeMac does not receive or store the password.

After approval, the app creates:

```text
/etc/sudoers.d/keepawakemac
```

The generated rule is scoped to the current macOS username and permits only:

```text
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

No wildcard arguments are granted. The rule does not grant a shell, arbitrary commands, arbitrary file writes, or general passwordless sudo.

Before installation, KeepAwakeMac validates the temporary rule with `visudo -cf`; after installation it validates **only its own fragment** with `visudo -cf /etc/sudoers.d/keepawakemac`. It deliberately does not run a global `visudo -c`, because a malformed sudoers fragment installed by an unrelated application must not make KeepAwakeMac's own install/remove operation fail.

## Runtime behavior

When lid mode is enabled, KeepAwakeMac:

1. checks that the two exact `pmset` commands are available,
2. reads `pmset -g`,
3. changes `disablesleep` only when it is currently off,
4. reads the value back and requires `SleepDisabled = 1`,
5. records whether KeepAwakeMac itself owns that global change,
6. opens the IOPM root-domain user client and enables the kernel clamshell-sleep guard,
7. re-applies that kernel guard during lid/power transitions and periodically while the mode is armed,
8. starts a companion watchdog with a heartbeat token,
9. optionally saves the built-in display brightness and sets the backlight to 0 while the physical lid is closed, and
10. restores all state when the session ends, the app quits, or the low-battery cutoff is reached.

If `SleepDisabled` was already enabled before KeepAwakeMac armed lid mode, the app does not claim ownership and does not automatically disable that external setting later.

## Internal kernel and display mechanisms

v1.3 uses two internal/undocumented macOS mechanisms for experimental lid behavior:

- the IOPM root-domain `kPMSetClamshellSleepState` external method (selector 12), and
- DisplayServices brightness functions for saving/restoring built-in display brightness.

These mechanisms do not widen the sudoers permission. They run in the logged-in user's process context, but because they are internal APIs they can change between macOS releases and are not intended for an App Store build.

## Crash-safety watchdog

The app bundle contains a separate executable:

```text
KeepAwakeLidWatchdog
```

It is launched only while lid mode is armed. The GUI creates a random-token heartbeat file in `~/Library/Caches/KeepAwakeMac/` and refreshes its modification time while running.

If the GUI process disappears, the token vanishes, or the heartbeat becomes stale, the companion attempts to:

- clear the kernel clamshell guard,
- run `sudo -n /usr/bin/pmset -a disablesleep 0` **only if the GUI told the helper that KeepAwakeMac owned that pmset state**,
- restore the saved built-in display brightness, and
- remove the temporary heartbeat/brightness files.

The helper receives no password and has no general sudo permission. The only privileged recovery operation it can perform without prompting is the exact `pmset ... disablesleep 0` command already allowed by the narrow sudoers rule.

## Removing authorization

Use **Remove Lid Authorization…** in the app. KeepAwakeMac first attempts to release its kernel lid guard, restore brightness, and restore normal `SleepDisabled` state if it owns that state. It then removes only:

```text
/etc/sudoers.d/keepawakemac
```

through a standard administrator prompt.

Manual removal is also possible:

```sh
sudo pmset -a disablesleep 0
sudo rm -f /etc/sudoers.d/keepawakemac
```

If you manually recover after an abnormal test, also quit/relaunch KeepAwakeMac so any in-process kernel clamshell connection is released. The companion watchdog is intended to perform this cleanup automatically after a crash.

## Password and lock-screen policy

KeepAwakeMac never asks for, receives, stores, or changes your macOS login password. It does not silently weaken Lock Screen settings.

In v1.3, closed-lid darkening uses built-in backlight brightness 0 rather than deliberately calling `pmset displaysleepnow`, so the app itself does not intentionally start the normal display-sleep password timer when it darkens a closed panel. macOS may still lock the user for other reasons according to system policy.

## Reporting a security issue

Use the repository's GitHub issue tracker for non-sensitive bugs. For a vulnerability that could expose credentials or grant privileges beyond the two documented `pmset` commands, do not publish passwords, tokens, or other secrets in a public issue; provide only the minimum reproduction information needed to identify the problem.
