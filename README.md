# ASUS ProArt PX13 – touchpad lag on battery fix

The touchpad on the **ASUS ProArt PX13 (HN7306W\*)** freezes or lags when the laptop runs on battery, mostly on the first touch after a short pause. On AC power it works fine, and an external mouse is smooth on battery too.

This repo has one PowerShell script that applies a set of Windows tweaks. It keeps them in place across driver updates, Armoury Crate plan switches and AC/DC changes, for **every power plan**.

> Tested on: ProArt PX13 HN7306WI, BIOS HN7306WI.318, AMD Ryzen AI 9 HX 370 / Radeon 890M (driver 32.0.13058.8001), RTX 4070 Laptop, Windows 11 25H2 (build 26200).
> Other Ryzen AI 300 ASUS laptops (Zenbook S16, ProArt P16, Vivobook S, etc.) use the same AMD I2C/GPIO stack and may benefit too. Use at your own risk.

---

## What the script changes

| # | Area | Change | Why |
|---|------|--------|-----|
| 1 | **Touchpad (I2C HID)** | `EnhancedPowerManagementEnabled = 0` on the touchpad device (`ACPI\ASCP1A00\*`) | Stops Windows from putting the touchpad to sleep between touches, which adds wake-up delay on the first touch after a pause. |
| 2 | **CPU on battery** (all power plans) | Battery (DC) processor policy made more responsive (see table below) | Stock DC values ramp the CPU very slowly (it waits for 90% load before boosting), so the input pipeline reacts slowly after idle. |
| 3 | **AMD display** | Disables Panel Self Refresh (PSR) and Panel Replay on AC **and** DC | The AMD driver ships with Replay **off on AC but on for battery** (`DalDisableReplayInAC=2`). This can cause cursor stutter on OLED panels. |
| 4 | **Persistence** | Scheduled task `TouchpadBatteryFix` (runs as SYSTEM) | Re-applies everything at boot, at logon and on every plug/unplug. AMD driver updates and Armoury Crate can reset these settings. |

### CPU on battery – exact values (DC only, AC is untouched)

| Setting | Stock DC | New DC |
|---|---|---|
| Energy Performance Preference | 60 | 25 |
| EPP (efficiency class 1) | 50 | 25 |
| Performance increase policy | Ideal | Rocket |
| Performance time check interval | 30 ms | 15 ms |
| Performance increase threshold | 90 % | 30 % |
| Performance increase threshold (class 1) | 90 % | 60 % |
| Idle promote / demote threshold | 40 / 20 | 60 / 40 (same as AC) |
| Core parking min cores | 25 % | 50 % |

**Not touched:** minimum/maximum processor state, the battery frequency cap, display refresh rate and brightness, services, drivers, BIOS and ASUS software. Battery life impact should be small.

---

## Install

1. Download the repo (**Code → Download ZIP**, or `git clone`) and extract it.
2. Open **PowerShell as Administrator** (Start → type `PowerShell` → *Run as administrator*).
3. Run:

   ```powershell
   cd "<path-to>\px13-touchpad-battery-fix"
   powershell -ExecutionPolicy Bypass -File .\fix.ps1 -Install
   ```

4. **Reboot** (the display change only takes effect after a reboot).

That's it. **You only need to run it once.** The install step:
- backs up your current settings to `C:\ProgramData\TouchpadBatteryFix\backup\`
- copies the script to `C:\ProgramData\TouchpadBatteryFix\fix.ps1`
- applies all changes
- creates the scheduled task that keeps them applied

> After an **AMD graphics driver update**, the task re-applies the display settings on the next boot. Reboot once more for the driver to pick them up.

## Check that it's working

- Log of every run: `C:\ProgramData\TouchpadBatteryFix\fix.log`
- Scheduled task: Task Scheduler → `TouchpadBatteryFix`
- Battery CPU values for the active plan:
  ```powershell
  powercfg /q SCHEME_CURRENT 54533251-82be-4824-96c1-47b60b740d00 36687f9e-e3a5-4dbf-b1dc-15eb381c6863
  ```
  `Current DC Power Setting Index` should be `0x00000019` (25).

## Uninstall / restore

From an **Administrator** PowerShell:

```powershell
# 1. remove the scheduled task
powershell -ExecutionPolicy Bypass -File C:\ProgramData\TouchpadBatteryFix\fix.ps1 -Uninstall

# 2. restore original registry values (display + touchpad)
Get-ChildItem C:\ProgramData\TouchpadBatteryFix\backup\*.reg | ForEach-Object { reg import $_.FullName }

# 3. restore original power plans (imported as new copies; pick them in Power Options)
Get-ChildItem C:\ProgramData\TouchpadBatteryFix\backup\*.pow | ForEach-Object { powercfg /import $_.FullName }
```

Reboot afterwards.

---

## Background / diagnosis notes

- The touchpad is an I2C HID device (`ACPI\ASCP1A00`, ACPI path `\_SB.I2CB.ETPD`) on AMD I2C controller `AMDI0010\1`. Its interrupt goes through the AMD GPIO controller (`AMDI0030`). ASUS's DialPad driver (`AsusDialPadDrv`) is installed on the touchpad's Precision Touchpad collection.
- The I2C controller drops to **D3** within a few seconds of no input. Its `_PS0`/`_PS3` ACPI methods power-gate it through AMD's AOAC (`DSAD`), so the first touch after idle has to wait for the controller to power back up.
- The AMD I2C driver (`amdi2c.sys` 1.2.0.126) ignores the standard KMDF `IdleInWorkingState=0` override. It only watches the *monitor on/off* power setting, not AC/DC.
- With an external mouse the cursor is smooth on battery, so the problem sits in the touchpad / I2C / GPIO input path rather than the display or overall system speed.
- After these changes the touchpad behaves normally on battery. Which change matters most has not been isolated; feedback is welcome (open an issue with your model and results).

## Disclaimer

Provided as-is, no warranty. It only changes Windows registry values and power plan settings, all of which are backed up and can be reverted with the steps above.
