# Security model

KeepAwakeMac's normal keep-awake mode does not require administrator privileges.

Lid-closed mode is different because it uses the system-wide macOS `pmset` setting `disablesleep`. That setting requires root privileges.

## What the one-time authorization installs

When you click **Install Lid Authorization…**, macOS shows a standard administrator authentication dialog. KeepAwakeMac does not receive or store the password.

After approval, the app creates:

```text
/etc/sudoers.d/keepawakemac
```

The generated rule is scoped to the current macOS username and permits only:

```text
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

No wildcard arguments are granted, and no shell, arbitrary command, file write, or general sudo permission is granted by this rule.

Before installing the file, the app validates it with `visudo -cf`. The installed sudoers configuration is also validated with `visudo -c`.

## Runtime behavior

When lid-closed mode is enabled, KeepAwakeMac:

1. checks that the narrow sudo permission exists,
2. reads the current `pmset -g` state,
3. changes `disablesleep` only if it is currently off,
4. reads `pmset -g` again and requires `SleepDisabled = 1`,
5. records whether KeepAwakeMac itself owns that change,
6. starts a watchdog and heartbeat,
7. restores `disablesleep 0` when the session stops, the app quits, the battery reaches the configured cutoff, or the watchdog detects that the owning process disappeared.

If `SleepDisabled` was already enabled before KeepAwakeMac armed lid mode, the app does not claim ownership and does not automatically turn that external setting off.

## Watchdog

While KeepAwakeMac owns `SleepDisabled`, it creates a random-token heartbeat file in the user's cache directory and launches a detached watchdog process. If the app process disappears or its heartbeat becomes stale, the watchdog attempts:

```sh
sudo -n /usr/bin/pmset -a disablesleep 0
```

The watchdog can do this without a password only because the sudoers rule permits that exact command.

## Removing authorization

Use **Remove Lid Authorization…** in the app. KeepAwakeMac first attempts to restore normal sleep if it owns `SleepDisabled`, then removes `/etc/sudoers.d/keepawakemac` through a standard administrator prompt.

Manual removal is also possible:

```sh
sudo rm -f /etc/sudoers.d/keepawakemac
sudo visudo -c
```

Before manually removing the rule, restore normal sleep if necessary:

```sh
sudo pmset -a disablesleep 0
```

## Password and lock-screen policy

KeepAwakeMac never asks for, receives, stores, or changes your macOS login password. It also does not silently weaken Lock Screen settings.

Whether macOS requires authentication after the display turns off is configured separately in **System Settings > Lock Screen**.

## Reporting a security issue

Please use the repository's GitHub issue tracker for non-sensitive bugs. For a vulnerability that would expose credentials or grant privileges beyond the two documented `pmset` commands, do not publish secrets or passwords in an issue; provide only the minimum reproduction information needed to identify the problem.
