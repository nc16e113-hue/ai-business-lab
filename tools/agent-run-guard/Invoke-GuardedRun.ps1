#requires -Version 5.1
<#
.SYNOPSIS
  Wrap an unattended (headless) command in the four guards an AI agent needs when
  it runs itself on a schedule with nobody watching.

.DESCRIPTION
  If you run something like `claude -p`, an autonomous agent, or any scheduled job
  that mutates shared state (git repo, files, a database) unattended, four failure
  modes bite that a normally-supervised program never hits. This wrapper handles all
  four. Each one below was learned by actually getting bitten -- see README.md.

    1. KILL SWITCH        A single file (STOP) that halts the run before it starts.
                          You need an out-of-band brake for a thing that runs while
                          you sleep.

    2. SINGLE-FLIGHT LOCK Two runs firing at once (a schedule catching up + you
                          triggering it by hand) will clobber each other's writes.
                          The lock is keyed by a per-run TOKEN, not by PID -- because
                          the process that writes the lock is usually not the process
                          that later checks it, and PID guessing mistakes your own
                          run for a rival and aborts it.

    3. SILENT-SUCCESS     A headless agent can exit 0 having done nothing (empty
       DETECTION          output). Exit code 0 is not proof of work. This treats an
                          empty/near-empty run as a failure and says so.

    4. MACHINE-READABLE    The next run has no memory of this one. A plain TSV log
       RUN LOG            lets a later run -- or you -- audit what actually happened.

.PARAMETER Command
  A scriptblock containing the work to run, e.g. { claude -p "daily digest" }.

.PARAMETER Name
  Short label for this job, used in the lock token and log lines. Default: 'run'.

.PARAMETER WorkDir
  Directory the guard files live in (STOP / .run-lock / run-guard.log). Default: '.'.

.PARAMETER StopFile
  Path to the kill-switch file. Default: <WorkDir>\STOP.

.PARAMETER LockFile
  Path to the single-flight lock. Default: <WorkDir>\.run-lock.

.PARAMETER StaleMinutes
  A lock older than this is considered abandoned and taken over. Default: 45.

.PARAMETER MinOutputChars
  Fewer non-whitespace output characters than this = treated as a silent failure.
  Default: 1 (i.e. truly empty output is the only silent failure).

.PARAMETER LogFile
  TSV run log. Default: <WorkDir>\run-guard.log.

.OUTPUTS
  A result object: Status (ok | stopped | standdown | silent-failure | error),
  ExitCode, OutputChars, Output, DurationSec. The process exit code mirrors Status
  (0 ok/stopped, 10 standdown, 20 silent-failure, 1 error) so a scheduler can react.

.EXAMPLE
  .\Invoke-GuardedRun.ps1 -Name nightly -WorkDir C:\agent -Command { claude -p "run the nightly job" }

.NOTES
  ASCII-only on purpose. Windows PowerShell 5.1 misreads a BOM-less UTF-8 .ps1 that
  contains non-ASCII text as ANSI and fails to parse it -- another lesson from the log.
  MIT licensed. Produced by the "AI CEO" experiment (https://note.com/ai_ceo_kei).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [scriptblock]$Command,
    [string]$Name = 'run',
    [string]$WorkDir = '.',
    [string]$StopFile,
    [string]$LockFile,
    [int]$StaleMinutes = 45,
    [int]$MinOutputChars = 1,
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'

# --- resolve paths -----------------------------------------------------------
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
if (-not $StopFile) { $StopFile = Join-Path $WorkDir 'STOP' }
if (-not $LockFile) { $LockFile = Join-Path $WorkDir '.run-lock' }
if (-not $LogFile)  { $LogFile  = Join-Path $WorkDir 'run-guard.log' }

# A token unique to THIS run. Identity is by token, never by PID: the scheduler
# process that writes the lock and the child process that later reads it differ,
# so PID comparison mistakes your own run for a competing one.
$Token = '{0} {1} {2}' -f $Name, (Get-Date -Format 'yyyy-MM-dd_HHmmss'), ([guid]::NewGuid().ToString('N'))

function Write-RunLog([string]$Event, [string]$Detail = '') {
    $line = "{0}`t{1}`t{2}`t{3}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Name, $Event, $Detail
    Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8
}

function New-Result([string]$Status, [int]$ExitCode, [int]$OutputChars, [string]$Output, [double]$DurationSec) {
    [pscustomobject]@{
        Status      = $Status
        ExitCode    = $ExitCode
        OutputChars = $OutputChars
        Output      = $Output
        DurationSec = [math]::Round($DurationSec, 1)
    }
}

# --- 1. KILL SWITCH ----------------------------------------------------------
if (Test-Path -LiteralPath $StopFile) {
    Write-RunLog 'stopped' 'STOP file present'
    Write-Warning "STOP file present ($StopFile) -> not running."
    New-Result 'stopped' 0 0 '' 0
    exit 0
}

# --- 2. SINGLE-FLIGHT LOCK ---------------------------------------------------
if (Test-Path -LiteralPath $LockFile) {
    $ageMin = ((Get-Date) - (Get-Item -LiteralPath $LockFile).LastWriteTime).TotalMinutes
    if ($ageMin -lt $StaleMinutes) {
        $held = (Get-Content -LiteralPath $LockFile -Raw).Trim()
        Write-RunLog 'standdown' ("held {0:N1} min: {1}" -f $ageMin, $held)
        Write-Warning ("Another run holds the lock ({0:N1} min old). Standing down." -f $ageMin)
        New-Result 'standdown' 10 0 '' 0
        exit 10
    }
    Write-RunLog 'lock-takeover' ("stale {0:N1} min" -f $ageMin)
    Remove-Item -LiteralPath $LockFile -Force
}
$Token | Out-File -LiteralPath $LockFile -Encoding utf8
Write-RunLog 'start' ("pid={0}" -f $PID)

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    # Run the work. Capture ALL output so we can measure it; keep the child's exit code.
    $global:LASTEXITCODE = 0
    $output = (& $Command 2>&1 | Out-String)
    $childExit = $LASTEXITCODE
    $sw.Stop()

    $chars = ($output -replace '\s', '').Length

    # --- 3. SILENT-SUCCESS DETECTION -----------------------------------------
    # Exit 0 is not proof of work. An empty run is a failure even when it is "green".
    if ($chars -lt $MinOutputChars) {
        Write-RunLog 'silent-failure' ("exit={0} chars={1}" -f $childExit, $chars)
        Write-Warning "Command exited but produced no real output ($chars chars). Treating as failure."
        New-Result 'silent-failure' 20 $chars $output $sw.Elapsed.TotalSeconds
        exit 20
    }

    Write-RunLog 'done' ("exit={0} chars={1} sec={2:N1}" -f $childExit, $chars, $sw.Elapsed.TotalSeconds)
    New-Result 'ok' $childExit $chars $output $sw.Elapsed.TotalSeconds
    exit 0
}
catch {
    $sw.Stop()
    Write-RunLog 'error' $_.Exception.Message
    Write-Warning ("Run threw: " + $_.Exception.Message)
    New-Result 'error' 1 0 '' $sw.Elapsed.TotalSeconds
    exit 1
}
finally {
    # Release only OUR lock. Never delete a lock whose token is not ours -- that would
    # be yanking a live sibling run's lock out from under it.
    if (Test-Path -LiteralPath $LockFile) {
        $cur = (Get-Content -LiteralPath $LockFile -Raw).Trim()
        if ($cur -eq $Token.Trim()) { Remove-Item -LiteralPath $LockFile -Force }
    }
}
