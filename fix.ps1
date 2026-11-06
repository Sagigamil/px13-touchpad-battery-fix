# Touchpad lag on battery - fix for ASUS ProArt PX13 (HN7306W*, Ryzen AI 9 HX 370 / Radeon 890M, OLED)
#
# Safe to run repeatedly. Must run elevated (Administrator) or as SYSTEM.
#   .\fix.ps1 -Install    : backup, copy to C:\ProgramData\TouchpadBatteryFix, apply,
#                           register scheduled task (boot, logon, every AC<->DC switch)
#   .\fix.ps1             : apply once (this is what the scheduled task runs)
#   .\fix.ps1 -Uninstall  : remove the scheduled task (see README to restore backups)
param([switch]$Install, [switch]$Uninstall)

$ErrorActionPreference = 'Continue'
$root   = 'C:\ProgramData\TouchpadBatteryFix'
$backup = Join-Path $root 'backup'
$log    = Join-Path $root 'fix.log'
New-Item -ItemType Directory -Force $root | Out-Null
function Log($m) { "$(Get-Date -Format s)  $m" | Out-File -Append -Encoding utf8 $log }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Error 'Run this script from an elevated (Administrator) PowerShell.'; exit 1 }

if ($Uninstall) {
    schtasks /Delete /TN 'TouchpadBatteryFix' /F | Out-Null
    Log 'Scheduled task removed'
    Write-Host 'Scheduled task removed. To restore original settings see README (backup folder).'
    return
}

$cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'

# ---------------------------------------------------------------------------
# Install: one-time backup + copy script to a stable location
# ---------------------------------------------------------------------------
if ($Install) {
    if (-not (Test-Path $backup)) {
        New-Item -ItemType Directory -Force $backup | Out-Null
        Get-ChildItem $cls -EA SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -EA SilentlyContinue
            if ($p.DriverDesc -match 'AMD|Radeon') {
                reg export ($_.Name) (Join-Path $backup "amd_display_$($_.PSChildName).reg") /y | Out-Null
            }
        }
        Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI' -EA SilentlyContinue |
          Where-Object { $_.PSChildName -match '^ASCP|^ASUE|^ELAN0|^SYNA|^MSFT0001' } | ForEach-Object {
            Get-ChildItem $_.PSPath | ForEach-Object {
                $dp = "$($_.Name)\Device Parameters"
                reg export $dp (Join-Path $backup ("touchpad_" + ($_.Name -replace '.*\\ACPI\\','' -replace '\\','_') + '.reg')) /y 2>$null | Out-Null
            }
        }
        (powercfg /list) | ForEach-Object {
            if ($_ -match '([0-9a-fA-F-]{36})') { powercfg /export (Join-Path $backup "scheme_$($matches[1]).pow") $matches[1] | Out-Null }
        }
        Log "Backup written to $backup"
    }
    $dest = Join-Path $root 'fix.ps1'
    if ($PSCommandPath -and ((Resolve-Path $PSCommandPath).Path -ne $dest)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $dest -Force
    }
}

# ---------------------------------------------------------------------------
# 1) Display: disable AMD Panel Self Refresh (PSR) / Panel Replay on AC and DC.
#    The AMD driver INF ships DalDisableReplayInAC=2, i.e. Replay is off on AC
#    but ON on battery. Driver updates reset these values; the scheduled task
#    re-applies them (a reboot is needed for the driver to pick them up).
# ---------------------------------------------------------------------------
$displayChanged = $false
Get-ChildItem $cls -EA SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -EA SilentlyContinue
    if ($p.DriverDesc -match 'AMD|Radeon') {
        $want = [ordered]@{
            DalPSRFeatureEnable            = 0   # Panel Self Refresh off
            DalFeatureEnablePsrSU          = 0   # PSR Selective Update off
            DalReplayEnableOption          = 0   # Panel Replay off (DC)
            DalReplayEnableOptionInAC      = 0   # Panel Replay off (AC)
            DalFreeSyncReplaySupport       = 0   # FreeSync Panel Replay off
            DalPSRAllowSMUOptimizations    = 0
            DalReplayAllowSMUOptimizations = 0
        }
        foreach ($n in $want.Keys) {
            $cur = $p.$n
            if ($cur -ne $want[$n]) {
                Set-ItemProperty -Path $_.PSPath -Name $n -Value $want[$n] -Type DWord
                Log "Display $($_.PSChildName): $n $cur -> $($want[$n])"
                $displayChanged = $true
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 2) Touchpad (I2C HID, ASCP1A00 on PX13): disable HID idle power management,
#    so the touchpad is not put to sleep between touches (wake latency on the
#    first touch after a pause).
# ---------------------------------------------------------------------------
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI' -EA SilentlyContinue |
  Where-Object { $_.PSChildName -match '^ASCP|^ASUE|^ELAN0|^SYNA|^MSFT0001' } | ForEach-Object {
    Get-ChildItem $_.PSPath | ForEach-Object {
        $dp = Join-Path $_.PSPath 'Device Parameters'
        if (Test-Path $dp) {
            $v = (Get-ItemProperty $dp -EA SilentlyContinue).EnhancedPowerManagementEnabled
            if ($v -ne 0) {
                Set-ItemProperty -Path $dp -Name EnhancedPowerManagementEnabled -Value 0 -Type DWord
                Log "Touchpad $($_.Name): EnhancedPowerManagementEnabled $v -> 0"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 3) Battery (DC) processor responsiveness, applied to EVERY power plan
#    (Armoury Crate switches between its own plans). Min/max processor state
#    and the DC frequency cap are NOT touched, so battery impact is small.
# ---------------------------------------------------------------------------
$SUB = '54533251-82be-4824-96c1-47b60b740d00'
$dc = [ordered]@{
    '36687f9e-e3a5-4dbf-b1dc-15eb381c6863' = 25  # Energy performance preference (0=perf,100=save), stock DC 60
    '36687f9e-e3a5-4dbf-b1dc-15eb381c6864' = 25  # EPP, efficiency class 1, stock DC 50
    '465e1f50-b610-473a-ab58-00d1077dc418' = 2   # Performance increase policy: Rocket (stock DC: Ideal)
    '4d2b0152-7d5c-498b-88e2-34345392a2c5' = 15  # Performance time check interval ms, stock DC 30
    '06cadf0e-64ed-448a-8927-ce7bf90eb35d' = 30  # Performance increase threshold %, stock DC 90
    '06cadf0e-64ed-448a-8927-ce7bf90eb35e' = 60  # Performance increase threshold, class 1, stock DC 90
    '7b224883-b3cc-4d79-819f-8374152cbe7c' = 60  # Idle promote threshold (= AC), stock DC 40
    '4b92d758-5a24-4851-a470-815d78aee119' = 40  # Idle demote threshold (= AC), stock DC 20
    '0cc5b647-c1df-4637-891a-dec35c318583' = 50  # Core parking min cores %, stock DC 25
}
$schemes = (powercfg /list) | ForEach-Object { if ($_ -match '([0-9a-fA-F-]{36})') { $matches[1] } } | Select-Object -Unique
foreach ($s in $schemes) {
    foreach ($g in $dc.Keys) {
        powercfg /setdcvalueindex $s $SUB $g $dc[$g] 2>$null | Out-Null
    }
}
powercfg /setactive SCHEME_CURRENT | Out-Null
Log "Processor DC settings applied to $(@($schemes).Count) schemes"

if ($displayChanged) { Log 'Display registry changed -> REBOOT REQUIRED to take effect' }

# ---------------------------------------------------------------------------
# Scheduled task: re-apply at boot, logon and every AC<->DC switch
# (Kernel-Power event 105), so driver updates / Armoury Crate can't undo it.
# ---------------------------------------------------------------------------
if ($Install) {
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Keeps ASUS PX13 touchpad responsive on battery (github: px13-touchpad-battery-fix).</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT30S</Delay></BootTrigger>
    <LogonTrigger><Enabled>true</Enabled><Delay>PT30S</Delay></LogonTrigger>
    <EventTrigger><Enabled>true</Enabled><Delay>PT5S</Delay>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=105]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <StartWhenAvailable>true</StartWhenAvailable>
  </Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$root\fix.ps1"</Arguments></Exec></Actions>
</Task>
"@
    $tmp = Join-Path $root 'task.xml'
    $xml | Out-File -Encoding unicode $tmp
    schtasks /Create /TN 'TouchpadBatteryFix' /XML $tmp /F | Out-Null
    Log "Scheduled task installed (exit $LASTEXITCODE)"
    Write-Host "Installed. Log: $log"
    if ($displayChanged) { Write-Host 'REBOOT REQUIRED for the display change to take effect.' -ForegroundColor Yellow }
}
