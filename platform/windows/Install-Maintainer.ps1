<#
.SYNOPSIS
    Register the maintainer tasks with the Windows Task Scheduler.

.DESCRIPTION
    The maintainer core is bash. On Windows that comes from Git Bash or WSL,
    and this script locates one rather than duplicating the logic in
    PowerShell. Two implementations of a security gate drift, and the gate is
    the whole product.

    Cadence maps onto New-ScheduledTaskTrigger -Daily -DaysInterval, which is
    the direct equivalent of the systemd OnCalendar stepping used on Linux.

.PARAMETER DryRun
    Print what would be registered and change nothing.

.EXAMPLE
    .\Install-Maintainer.ps1
    .\Install-Maintainer.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$RepoPath = "$env:USERPROFILE\Desktop\lacs"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-Bash {
    # Preference order: Git Bash, then WSL. Both run the same run.sh.
    $candidates = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) { return 'wsl.exe' }
    throw "No bash found. Install Git for Windows or enable WSL; the maintainer core is bash and is not reimplemented here."
}

$bash  = Find-Bash
$share = Join-Path $env:USERPROFILE '.local\share\maintainer'
$runSh = Join-Path $share 'run.sh'

if (-not (Test-Path $runSh)) {
    throw "run.sh not found at $runSh. Run install.sh under bash first to deploy the files."
}

# Task name -> hour, minute, day interval. Mirrors the Linux timers exactly.
$tasks = @(
    @{ Name = 'review'; Hour =  9; Minute = 13; Days = 1 },
    @{ Name = 'issues'; Hour = 10; Minute = 41; Days = 2 },
    @{ Name = 'ci';     Hour = 11; Minute = 27; Days = 3 },
    @{ Name = 'audit';  Hour = 12; Minute = 19; Days = 5 }
)

foreach ($t in $tasks) {
    $taskName = "maintainer-sysknife-$($t.Name)"
    $at = (Get-Date -Hour $t.Hour -Minute $t.Minute -Second 0)

    if ($bash -eq 'wsl.exe') {
        $argument = "-e bash -lc `"'$runSh' sysknife $($t.Name)`""
    } else {
        $argument = "-lc `"'$runSh' sysknife $($t.Name)`""
    }

    if ($DryRun) {
        Write-Host ("  would register {0}: {1} {2} every {3} day(s) at {4:HH:mm}" -f `
            $taskName, $bash, $argument, $t.Days, $at)
        continue
    }

    $action  = New-ScheduledTaskAction -Execute $bash -Argument $argument -WorkingDirectory $RepoPath
    $trigger = New-ScheduledTaskTrigger -Daily -DaysInterval $t.Days -At $at
    # StartWhenAvailable is the closest equivalent to systemd's Persistent=true:
    # a run missed while the machine was off starts once it is on again.
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -DontStopIfGoingOnBatteries `
        -AllowStartIfOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 90) `
        -MultipleInstances IgnoreNew
    # Interactive-token principal on purpose: the agent needs the user's own
    # gh and model credentials, and must not run with elevated rights.
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host "  registered $taskName (every $($t.Days) day(s) at $($at.ToString('HH:mm')))"
}

if (-not $DryRun) {
    Write-Host "  done. Inspect with: Get-ScheduledTask -TaskName 'maintainer-*'"
    Write-Host "  remove with:        Get-ScheduledTask -TaskName 'maintainer-*' | Unregister-ScheduledTask -Confirm:`$false"
}
