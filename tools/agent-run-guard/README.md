# agent-run-guard

**Four guards for a command that runs itself while nobody is watching.**

日本語の解説はこちら → [note.com/ai_ceo_kei](https://note.com/ai_ceo_kei) ／ ツール一覧 → [AI活用ラボ](https://ai-lab.hatayama-pro.com/tools.html)

---

If you schedule an AI agent — `claude -p`, an autonomous script, any headless job that
edits shared state (a git repo, files, a database) — with no human at the keyboard, four
failure modes bite you that a normally-supervised program never hits. This is a single
PowerShell wrapper that handles all four.

Every guard here exists because the failure it prevents actually happened, in production,
to an AI that was running itself on a schedule. None of them is something you'd think to
build for a program a human babysits. That's the point.

## The four guards

| # | Guard | The failure it prevents |
|---|-------|-------------------------|
| 1 | **Kill switch** | You need an out-of-band brake for a thing that runs while you sleep. One file (`STOP`) halts the next run before it starts. |
| 2 | **Single-flight lock** | The schedule catches up late *and* you trigger the job by hand — now two runs are writing the same files at once. The lock stops the second one. |
| 3 | **Silent-success detection** | A headless agent exited `0` and produced **nothing**. Exit code 0 is not proof of work. This treats an empty run as the failure it is. |
| 4 | **Machine-readable run log** | The next run has no memory of this one. A plain TSV log lets a later run — or you — audit what actually happened. |

## Why these, and not the usual ones

**The lock is keyed by a token, not a PID.** The obvious way to detect a concurrent run
is "is the PID in the lock file still alive?" It fails, because *the process that writes
the lock is usually not the process that checks it* — a scheduler launches a runner, the
runner launches the agent, and each has a different PID. PID-guessing made a real bin
mistake its **own** runner for a rival and abort its work (one evening run did ~1 minute
and committed nothing). So identity here is a unique token each run writes and only ever
deletes if it still owns it. It also means a run never yanks a live sibling's lock.

**"Exit 0" is treated as a claim, not a fact.** The single most expensive lesson from
running an AI unattended: green is not the same as correct. A headless agent can return
success having done nothing; a status code, a log line, even a "SENT" can all be green
while the real work silently didn't happen. Guard 3 is the smallest possible antidote —
it refuses to call an empty run a success. (If you take one idea from this repo, take
this one, and go add an *independent* check to whatever you already trust.)

## Usage

```powershell
.\Invoke-GuardedRun.ps1 -Name nightly -WorkDir C:\agent -Command { claude -p "run the nightly job" }
```

Any scriptblock works — it doesn't have to be an AI agent:

```powershell
.\Invoke-GuardedRun.ps1 -Name backup -WorkDir C:\jobs -Command { & robocopy C:\data D:\backup /MIR }
```

It returns a result object and mirrors the outcome in its exit code, so a scheduler can react:

| Status | Exit | Meaning |
|--------|------|---------|
| `ok` | 0 | ran, produced real output |
| `stopped` | 0 | `STOP` file present, did not run |
| `standdown` | 10 | another run holds the lock |
| `silent-failure` | 20 | ran but produced no real output |
| `error` | 1 | the command threw |

To stop all future runs, drop a file named `STOP` in the work directory. Delete it to resume.

### Parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `-Command` | *(required)* | Scriptblock with the work to run. |
| `-Name` | `run` | Label used in the lock token and log. |
| `-WorkDir` | `.` | Where `STOP` / `.run-lock` / `run-guard.log` live. |
| `-StaleMinutes` | `45` | A lock older than this is considered abandoned and taken over. |
| `-MinOutputChars` | `1` | Fewer non-whitespace output chars than this = silent failure. |
| `-StopFile` / `-LockFile` / `-LogFile` | *(under WorkDir)* | Override individual paths. |

## Requirements

Windows PowerShell 5.1+ or PowerShell 7+. No modules, no network, no dependencies —
one file. (The script is deliberately ASCII-only: PowerShell 5.1 misreads a BOM-less
UTF-8 `.ps1` containing non-ASCII text as ANSI and fails to parse it. That, too, is a
lesson from the log.)

## Where this came from

This is a byproduct of the ["AI CEO" experiment](https://note.com/ai_ceo_kei): an AI
given a directory, a plan, and permission to run itself on a schedule and publish what
it makes. Guards like these are the tools it turned out to need to survive being its own
unsupervised operator. A human software company never builds them, because a human company
never leaves an AI running itself with nobody home.

MIT licensed — see [LICENSE](LICENSE). Use it, fork it, strip out what you don't need.
