# Hyper-V Sleep Guard

Keeps a Windows host from idle-sleeping while any Hyper-V VM is running.

## Why

Hyper-V does not assert a power request on the host's behalf, so as far as Windows is
concerned a machine running a busy VM is idle. Once the power plan's idle timeout elapses
the host sleeps and takes the running VMs down with it.

The guard is a small PowerShell loop that polls `Get-VM` every 30 seconds and holds a
`SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)` power request while at least
one VM is Running / Starting / Resuming. It runs as SYSTEM from a scheduled task started at
boot, because `Get-VM` needs elevation and the guard has to survive logoff.

What it deliberately does *not* do:

- It does not set `ES_DISPLAY_REQUIRED`, so your monitor still blanks on schedule.
- It does not block manual sleep. Choosing Sleep from the Start menu still works.
- It does not touch your power plan. Uninstalling leaves no settings to revert.

If the guard process dies for any reason the flag dies with it, so the failure mode is
"normal sleep behaviour returns", never "PC pinned awake forever".

## Requirements

- Windows with the Hyper-V role enabled (developed against Windows 11 Pro, S3 sleep).
- Windows PowerShell 5.1 (ships with Windows; no modules beyond `Hyper-V` and
  `ScheduledTasks`).
- Local administrator rights to install. `Get-VM` fails for a non-elevated caller unless
  the account is in the `Hyper-V Administrators` group, which is why the guard runs as
  SYSTEM.

## Install

```powershell
git clone https://github.com/dvdsmn/hyperv-sleepguard.git
cd hyperv-sleepguard
```

Then, from an **elevated** PowerShell prompt in that directory:

```powershell
.\Install-SleepGuard.ps1
```

That copies `HyperVSleepGuard.ps1` to `C:\ProgramData\HyperVSleepGuard\`, restricts the
folder to Administrators/SYSTEM for write (a SYSTEM task should not execute a script a
non-elevated process can rewrite), registers the task `HyperV Sleep Guard`, and starts it.

Re-run it after editing `HyperVSleepGuard.ps1` to redeploy.

Options: `-IntervalSeconds`, `-InstallDir`, `-TaskName`.

### If script execution is blocked

Windows clients default to the `Restricted` execution policy, which refuses to run any
script. On such a machine the install fails before it does anything:

```
.\Install-SleepGuard.ps1 : File ...\Install-SleepGuard.ps1 cannot be loaded because running
scripts is disabled on this system.
```

Only the scripts you start by hand are affected. The scheduled task launches the guard with
`-ExecutionPolicy Bypass`, so once installed it runs regardless of the machine's policy.

Run the installer in a process that bypasses the policy:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SleepGuard.ps1
```

The bypass applies to that one process, so the machine's policy is never modified and there is
nothing to revert. Use the same form for `Uninstall-SleepGuard.ps1`.

If you would rather relax the policy than bypass it, `RemoteSigned` is enough, but scripts
extracted from a downloaded ZIP carry a mark of the web and are still rejected as unsigned.
Clear it with `Get-ChildItem *.ps1 | Unblock-File`, or clone the repo, which does not set the
mark.

Background: [about_Execution_Policies](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_execution_policies).

## Verify

All from an elevated prompt:

```powershell
# 1. Task is alive (LastTaskResult 267009 = still running)
Get-ScheduledTask 'HyperV Sleep Guard' | Get-ScheduledTaskInfo

# 2. No VM running -> SYSTEM: None
powercfg /requests

# 3. Start a VM, wait <= 30s, run again -> SYSTEM lists powershell.exe
powercfg /requests

# 4. Stop the VM, wait <= 30s -> back to None
powercfg /requests

# 5. One line per transition
Get-Content C:\ProgramData\HyperVSleepGuard\guard.log -Tail 20
```

Then the real test: leave a VM running past the 30-minute idle timeout and confirm the host
is still up.

## Troubleshooting

**Task shows a non-zero LastTaskResult / exits immediately.** Check the log first; if it is
empty the script never started. Run the same command line by hand from an elevated prompt to
see the error:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\HyperVSleepGuard\HyperVSleepGuard.ps1
```

**Log shows repeated `Get-VM failed`.** The account running the task cannot read VM state.
The task must run as `SYSTEM` with RunLevel Highest; confirm with
`(Get-ScheduledTask 'HyperV Sleep Guard').Principal`.

**PC still asleep despite a running VM.** Confirm the request is actually held with
`powercfg /requests`, then check nothing overrides it:
`powercfg /requestsoverride` should not list powershell.exe.

**PC stays awake with no VM running.** PowerToys Awake left in indefinite mode holds its own
request and shows up in `powercfg /requests` independently of this guard. Awake has no
conditional mode and cannot watch VM state, which is why it is not used here. Keep it for
manual ad-hoc "stay awake for 2 hours".

## Uninstall

```powershell
.\Uninstall-SleepGuard.ps1        # add -KeepLog to leave C:\ProgramData\HyperVSleepGuard
```

## License

MIT. See [LICENSE](LICENSE).
