<#
.SYNOPSIS
    Prevents the host from idle-sleeping while any Hyper-V VM is running.

.DESCRIPTION
    Polls Get-VM on an interval. While at least one VM is Running/Starting/Resuming,
    holds a system power request via SetThreadExecutionState(ES_CONTINUOUS |
    ES_SYSTEM_REQUIRED). Releases it when the last VM stops.

    ES_DISPLAY_REQUIRED is deliberately NOT set: the monitor still blanks on schedule,
    and manually choosing Sleep from the Start menu still works. Only idle sleep is blocked.

    The flag is per-thread and lives only as long as this process, so a crash fails safe
    (normal sleep behaviour returns) rather than pinning the machine awake.

    Requires elevation / SYSTEM: Get-VM fails for a non-elevated caller unless the account
    is in the Hyper-V Administrators group.
#>
[CmdletBinding()]
param(
    [int]    $IntervalSeconds = 30,
    [string] $LogPath         = 'C:\ProgramData\HyperVSleepGuard\guard.log',
    [int]    $MaxLogBytes     = 1MB
)

$ErrorActionPreference = 'Stop'

Add-Type -Namespace HyperVSleepGuard -Name Power -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@

# In PS 5.1 the literal 0x80000000 parses as Int32 (-2147483648) and casting that to
# uint32 throws; the L suffix forces Int64 first so the cast is in range.
$ES_CONTINUOUS       = [uint32]0x80000000L
$ES_SYSTEM_REQUIRED  = [uint32]0x00000001

$AwakeStates = @('Running', 'Starting', 'Resuming')

function Write-GuardLog {
    param([string]$Message)

    try {
        $dir = Split-Path -Parent $LogPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        if ((Test-Path -LiteralPath $LogPath) -and
            ((Get-Item -LiteralPath $LogPath).Length -gt $MaxLogBytes)) {
            Move-Item -LiteralPath $LogPath -Destination "$LogPath.old" -Force
        }

        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -LiteralPath $LogPath -Value "$stamp  $Message" -Encoding UTF8
    } catch {
        # Logging must never take the guard down.
    }
}

function Set-SleepBlock {
    param([bool]$Enabled)

    $flags = if ($Enabled) { $ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED } else { $ES_CONTINUOUS }
    $prev  = [HyperVSleepGuard.Power]::SetThreadExecutionState($flags)
    if ($prev -eq 0) {
        Write-GuardLog "WARN  SetThreadExecutionState(0x$($flags.ToString('X8'))) failed."
        return $false
    }
    return $true
}

Write-GuardLog "START pid=$PID interval=${IntervalSeconds}s"

# $null = unknown (we have not successfully read VM state yet)
$blocking    = $null
$lastVmError = $null

try {
    while ($true) {
        $awakeVms = $null

        try {
            $awakeVms = @(Get-VM | Where-Object { $AwakeStates -contains $_.State.ToString() })
            $lastVmError = $null
        } catch {
            # vmms is typically not ready for the first few seconds after boot. Hold the
            # current state rather than releasing the block on a transient failure.
            $msg = $_.Exception.Message
            if ($msg -ne $lastVmError) {
                Write-GuardLog "WARN  Get-VM failed, holding previous state: $msg"
                $lastVmError = $msg
            }
        }

        if ($null -ne $awakeVms) {
            $shouldBlock = $awakeVms.Count -gt 0

            if ($shouldBlock) {
                # Re-assert every tick: idempotent, and insurance in case the runspace
                # ever moves to a different thread (the flag is per-thread).
                Set-SleepBlock -Enabled $true | Out-Null
                if ($blocking -ne $true) {
                    $names = ($awakeVms | ForEach-Object { $_.Name }) -join ', '
                    Write-GuardLog "BLOCK sleep blocked; running: $names"
                    $blocking = $true
                }
            } elseif ($blocking -ne $false) {
                Set-SleepBlock -Enabled $false | Out-Null
                Write-GuardLog 'FREE  no VMs running; normal sleep restored'
                $blocking = $false
            }
        }

        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    # Belt and braces; the flag dies with the process anyway.
    [HyperVSleepGuard.Power]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null
    Write-GuardLog "STOP  pid=$PID exiting"
}
