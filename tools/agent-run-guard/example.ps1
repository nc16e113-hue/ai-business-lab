# Example: wrap a headless `claude -p` run in the guard, the way a scheduled job would.
#
# Run it by hand first to see the guards work, then point Windows Task Scheduler (or
# cron, via pwsh) at this file. Running it twice at once demonstrates the lock:
# the second invocation stands down instead of racing the first.

$guard = Join-Path $PSScriptRoot 'Invoke-GuardedRun.ps1'
$work  = $PSScriptRoot   # STOP / .run-lock / run-guard.log will live here

$result = & $guard -Name 'demo' -WorkDir $work -Command {
    # Replace this block with your real unattended work, e.g.:
    #   'Summarize today''s commits in two sentences.' | claude -p --permission-mode auto
    Write-Output "pretend an AI agent did some work here at $(Get-Date -Format o)"
}

# React to the outcome. Note we check Status, not just a zero exit code -- because the
# whole point of guard 3 is that a zero exit code can lie.
switch ($result.Status) {
    'ok'             { Write-Host "OK: $($result.OutputChars) chars in $($result.DurationSec)s" }
    'stopped'        { Write-Host 'Halted by STOP file.' }
    'standdown'      { Write-Host 'Another run is already going; did nothing.' }
    'silent-failure' { Write-Host 'Ran but produced nothing -- investigate, do NOT trust the green.' }
    'error'          { Write-Host 'The command threw.' }
}
