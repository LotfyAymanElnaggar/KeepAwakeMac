# KeepAwakeMac v1.1.2

This patch fixes lid-authorization handling when another app has a broken file in `/etc/sudoers.d`.

The issue was reproduced from diagnostics showing Amphetamine's `amphetamine_PowerProtect` fragment with incorrect permissions. KeepAwakeMac v1.1.1 performed a global `visudo -c` after installing or removing its own rule, so an unrelated third-party sudoers error could make KeepAwakeMac report that its own operation failed.

## Fixed

- **No global sudoers validation:** KeepAwakeMac now validates only its own `/etc/sudoers.d/keepawakemac` fragment with `visudo -cf`.
- **Third-party sudoers errors no longer block removal:** removing KeepAwakeMac authorization deletes only its own file and does not fail because Amphetamine, or another app, has a malformed fragment.
- **Correct authorization ownership:** the UI now treats "Lid Authorization installed" as the existence of KeepAwakeMac's own sudoers fragment, rather than inferring it from `sudo -l`. This prevents another app that grants similar `pmset` access from making KeepAwakeMac look installed after its file has already been removed.
- **Separate privilege detection:** KeepAwakeMac still checks whether the exact two `pmset disablesleep` commands are actually executable without a password before arming lid mode.
- **Foreign sudoers warnings captured in Diagnostics** instead of being mistaken for KeepAwakeMac installation/removal failures.
- Keeps the v1.1.1 fixed 400 × 620 menu-bar pop-up sizing.

## What the supplied diagnostics confirmed

The normal keep-awake engine was active and working: macOS reported KeepAwakeMac-owned `PreventSystemSleep` and `PreventUserIdleSystemSleep` assertions and showed idle sleep as prevented. Lid mode itself was not armed because `SleepDisabled` read back as `0`.

For actual lid-closed operation, enable **Keep running with lid closed** and confirm the menu reports `SleepDisabled = 1` before closing the lid.

## Amphetamine warning

If Diagnostics reports:

```text
/private/etc/sudoers.d/amphetamine_PowerProtect: bad permissions, should be mode 0440
```

that file belongs to Amphetamine, not KeepAwakeMac. v1.1.2 will no longer let that unrelated warning break KeepAwakeMac's own install/remove flow. You may still want to repair or remove the stale Amphetamine Power Protect authorization separately.

## Safety

Lid-closed mode disables normal system sleep globally while armed. Do not put the MacBook in a bag, sleeve, drawer, or other poorly ventilated location while `SleepDisabled = 1`.

If normal sleep ever fails to return, restore it with:

```sh
sudo pmset -a disablesleep 0
```

and verify with:

```sh
pmset -g | grep -i SleepDisabled
```

Expected value after restoration: `0`.
