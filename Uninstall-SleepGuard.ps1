<#
.SYNOPSIS
    Removes the HyperV Sleep Guard scheduled task and its deployed files.

.DESCRIPTION
    Unregisters the task (which kills the guard process and releases the power request)
    and deletes C:\ProgramData\HyperVSleepGuard. No power settings were ever modified by
    this project, so nothing else needs undoing.

    Must be run from an elevated PowerShell prompt.
#>
[CmdletBinding()]
param(
    [string] $InstallDir = 'C:\ProgramData\HyperVSleepGuard',
    [string] $TaskName   = 'HyperV Sleep Guard',
    [switch] $KeepLog
)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Uninstall-SleepGuard.ps1 must be run from an elevated PowerShell prompt.'
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Write-Host "Stopping and unregistering '$TaskName' ..."
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch { }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
} else {
    Write-Host "Task '$TaskName' is not registered; nothing to unregister."
}

if ($KeepLog) {
    Write-Host "Leaving $InstallDir in place (-KeepLog)."
} elseif (Test-Path -LiteralPath $InstallDir) {
    Write-Host "Removing $InstallDir ..."
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
}

Write-Host 'Uninstalled. Confirm with:  powercfg /requests'
