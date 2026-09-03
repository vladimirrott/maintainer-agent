<#
.SYNOPSIS
    Register the maintainer tasks with the Windows Task Scheduler.

.DESCRIPTION
    The maintainer core is bash. On Windows that comes from Git Bash or WSL,
    and this script locates one rather than duplicating the logic in
    PowerShell. Two implementations of a security gate drift, and the gate is
    the whole product.

    Every task is registered as a DAILY trigger. The real cadence is
    MIN_HOURS_<task> in the profile's profile.env, which run.sh enforces on
    every platform, so a machine that was off overnight resumes the next day
    instead of waiting out a multi-day interval it already missed.

.PARAMETER DryRun
    Print what would be registered and change nothing.

.EXAMPLE
    .\Install-Maintainer.ps1
    .\Install-Maintainer.ps1 -DryRun
    .\Install-Maintainer.ps1 -ProfileName widget
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$ProfileName = 'sysknife',
    [string]$RepoPath
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

# The task list comes from the deployed profile, not from this file. A second
# repository must not need an edit here.
$envFile = Join-Path $share "profiles\$ProfileName\profile.env"
if (-not (Test-Path $envFile)) {
    throw "No deployed profile '$ProfileName' at $envFile. Run install.sh under bash first."
}
$envText = Get-Content $envFile -Raw
$taskNames = ([regex]::Match($envText, 'TASKS="([^"]*)"').Groups[1].Value) -split '\s+' |
    Where-Object { $_ }
if (-not $taskNames) { throw "Could not read TASKS from $envFile" }
if (-not $RepoPath) {
    $RepoPath = [regex]::Match($envText, 'REPO_PATH="[^"]*:-([^"}]*)').Groups[1].Value
    if (-not $RepoPath) { $RepoPath = $env:USERPROFILE }
}

$hour = 9
$tasks = foreach ($n in $taskNames) {
    @{ Name = $n; Hour = $hour; Minute = 17 }
    $hour++
}

foreach ($t in $tasks) {
    $taskName = "maintainer-$ProfileName-$($t.Name)"
    $at = (Get-Date -Hour $t.Hour -Minute $t.Minute -Second 0)

    if ($bash -eq 'wsl.exe') {
        $argument = "-e bash -lc `"'$runSh' $ProfileName $($t.Name)`""
    } else {
        $argument = "-lc `"'$runSh' $ProfileName $($t.Name)`""
    }

    if ($DryRun) {
        Write-Host ("  would register {0}: {1} {2} daily at {3:HH:mm}" -f `
            $taskName, $bash, $argument, $at)
        continue
    }

    $action  = New-ScheduledTaskAction -Execute $bash -Argument $argument -WorkingDirectory $RepoPath
    $trigger = New-ScheduledTaskTrigger -Daily -DaysInterval 1 -At $at
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
    Write-Host "  registered $taskName (daily at $($at.ToString('HH:mm')); cadence from MIN_HOURS_$($t.Name))"
}

if (-not $DryRun) {
    Write-Host "  done. Inspect with: Get-ScheduledTask -TaskName 'maintainer-*'"
    Write-Host "  remove with:        Get-ScheduledTask -TaskName 'maintainer-*' | Unregister-ScheduledTask -Confirm:`$false"
}
