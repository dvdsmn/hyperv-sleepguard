<#
.SYNOPSIS
    Installs HyperVSleepGuard.ps1 as a SYSTEM scheduled task that runs at startup.

.DESCRIPTION
    Copies the guard script to C:\ProgramData\HyperVSleepGuard, tightens the ACL so a
    non-elevated process cannot rewrite a script that SYSTEM executes, then registers and
    starts the task. Re-running this is safe: it overwrites the deployed script and the
    task definition in place.

    Must be run from an elevated PowerShell prompt.
#>
[CmdletBinding()]
param(
    [string] $InstallDir       = 'C:\ProgramData\HyperVSleepGuard',
    [string] $TaskName         = 'HyperV Sleep Guard',
    [int]    $IntervalSeconds  = 30
)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Install-SleepGuard.ps1 must be run from an elevated PowerShell prompt.'
}

$source = Join-Path $PSScriptRoot 'HyperVSleepGuard.ps1'
if (-not (Test-Path -LiteralPath $source)) {
    throw "Cannot find HyperVSleepGuard.ps1 next to this installer (looked in $PSScriptRoot)."
}

$target = Join-Path $InstallDir 'HyperVSleepGuard.ps1'

Write-Host "Deploying to $InstallDir ..."
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item -LiteralPath $source -Destination $target -Force

# SYSTEM runs this script, so only administrators may write to it.
Write-Host 'Tightening ACL (Administrators/SYSTEM full, Users read-only) ...'
& icacls.exe $InstallDir /inheritance:r `
    /grant '*S-1-5-18:(OI)(CI)F' `
    /grant '*S-1-5-32-544:(OI)(CI)F' `
    /grant '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed with exit code $LASTEXITCODE." }

Write-Host "Registering scheduled task '$TaskName' ..."
$argument = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden ' +
            "-File `"$target`" -IntervalSeconds $IntervalSeconds"

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument

$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = 'PT30S'   # give vmms a moment to come up

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
    -LogonType ServiceAccount -RunLevel Highest

# ExecutionTimeLimit Zero = unlimited. The default 3-day cap would silently kill the guard.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -DontStopOnIdleEnd `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Description `
    'Holds a system power request while any Hyper-V VM is running.' -Force | Out-Null

Write-Host 'Starting task ...'
Start-ScheduledTask -TaskName $TaskName

Start-Sleep -Seconds 3
Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo |
    Select-Object TaskName, LastRunTime, LastTaskResult, NumberOfMissedRuns

Write-Host ''
Write-Host 'Installed. Verify with:  powercfg /requests'
Write-Host "Log:                     $(Join-Path $InstallDir 'guard.log')"
