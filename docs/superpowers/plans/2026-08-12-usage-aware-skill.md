# usage-aware Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A standalone Claude Code skill + SessionStart hook that injects the account's rate-limit usage (week/session %) into context at session start and instructs Claude to adapt its behavior via three frugality tiers.

**Architecture:** A PowerShell (and POSIX sh) SessionStart hook reads the freshest of Clawdometer's `~/.clawdometer/live.json` or its own `~/.claude/usage-aware/cache.json`, prints one `[usage] …` line with a computed tier. When both are stale it spawns a detached refresher (same script, `-Refresh` mode) that runs `claude -p --no-session-persistence /usage`, parses the report, and atomically writes the cache. A `SKILL.md` documents the tier rules. Everything fails open: missing/malformed data prints nothing and never throttles.

**Tech Stack:** PowerShell 5.1, POSIX sh, no external dependencies (no jq, no Pester — plain assertion scripts).

**Spec:** `docs/superpowers/specs/2026-08-12-usage-aware-skill-design.md` — read it first.

## Global Constraints

- PowerShell 5.1 compatible: no `&&`/`||` pipeline chains, no ternary, no `??`.
- All failure modes fail open: exit 0, print nothing (or a `(stale)` line with no tier). A hook error must never block session start.
- Recursion guard: `USAGE_AWARE_REFRESH=1` in env → hook exits immediately, before any file I/O.
- Tier thresholds (weekly %): `<60` normal, `60–85` frugal, `>85` minimal. Session % is displayed, never drives tier.
- Freshness windows: live.json 15 min, cache.json 10 min, stale-display cutoff 24 h, lockfile 5 min, refresher timeout 60 s.
- Source of truth is this repo (claude-usage-aware). Install copies to `~/.claude/`. The Clawdometer repo is never touched.
- Test overrides: `USAGE_AWARE_DIR` (cache+lock dir), `CLAWDOMETER_DIR` (live.json dir), `USAGE_AWARE_NO_SPAWN=1` (suppress refresher spawn in tests).
- Commit after every task. Messages: `feat(usage-aware): …` / `test(usage-aware): …`.

## File Structure

```
claude-usage-aware/  (repo root)
  SKILL.md                     # tier rules; installed to ~/.claude/skills/usage-aware/
  hooks/usage-tier.ps1         # hook + refresher, Windows
  hooks/usage-tier.sh          # hook + refresher, POSIX
  install.ps1                  # copies files, merges settings.json (backup first)
  tests/fixtures/report.txt    # verbatim /usage report (from usage_refresher.rs test const)
  tests/test-usage-tier.ps1    # plain-PS assertion harness
  tests/test-usage-tier.sh     # plain-sh assertion harness
  README.md                    # what it is, how to install, how to uninstall
```

---

### Task 1: Scaffold + SKILL.md

**Files:**
- Create: `SKILL.md`
- Create: `tests/fixtures/report.txt`

**Interfaces:**
- Produces: the repo directory layout all later tasks write into; `report.txt` consumed by Tasks 3–5 tests.

- [ ] **Step 1: Create fixture** — the report below is captured from Clawdometer's `usage_refresher.rs` test constant (CLI v2.1.207). Content of `tests/fixtures/report.txt` (the `·` is U+00B7):

```
You are currently using your subscription to power your Claude Code usage

Current session: 32% used · resets Jul 13, 3:29pm (Asia/Saigon)
Current week (all models): 39% used · resets Jul 16, 9:59am (Asia/Saigon)
Current week (Fable): 54% used · resets Jul 16, 9:59am (Asia/Saigon)

What's contributing to your limits usage?
```

- [ ] **Step 2: Write `SKILL.md`**

```markdown
---
name: usage-aware
description: Adapt behavior to the account's Claude rate-limit budget. Use when the user asks "how much usage/limit do I have left", "am I close to my limit", "check my usage", or when a [usage] line in context shows tier frugal/minimal and you are about to start expensive work (subagents, workflows, large reads).
---

# usage-aware

A SessionStart hook injects one line at session start:

    [usage] week 39% · session 32% · week resets Jul 16, 9:59am · tier: normal

`week` is the 7-day all-models window — it drives the tier. `session` is the
5-hour window — display only, never throttle on it (it resets too fast).

## Tiers

| Week % | Tier | Behavior |
|---|---|---|
| < 60 | normal | No change. |
| 60–85 | frugal | No subagents or workflows unless the user asks. Targeted reads (Grep, offset/limit) over whole-file reads. No speculative refactors or drive-by cleanups. Prefer editing over regenerating. |
| > 85 | minimal | Smallest change that works. Confirm with the user before any subagent, workflow, or read over ~500 lines. No exploratory searches beyond what the task strictly needs. |

## Rules

- No `[usage]` line, or a line marked `(stale)` with no tier → behave normally.
  Missing data must never throttle.
- When starting a long or expensive task and the `[usage]` line is over an
  hour old, re-read the freshest of `~/.clawdometer/live.json`
  (`rate_limits.seven_day.used_percentage`) or
  `~/.claude/usage-aware/cache.json` (`week_pct`) with the Read tool and
  recompute the tier. Do NOT run `claude -p /usage` yourself — the hook's
  background refresher handles fetching.
- When the user asks how much usage they have left, report both windows and
  reset times from the freshest source above, plus the current tier.
```

- [ ] **Step 3: Commit**

```bash
git add .
git commit -m "feat(usage-aware): scaffold skill with tier rules and report fixture"
```

---

### Task 2: Hook reading logic (`usage-tier.ps1`)

**Files:**
- Create: `hooks/usage-tier.ps1`
- Test: `tests/test-usage-tier.ps1`

**Interfaces:**
- Produces: `usage-tier.ps1` invoked with no args = hook mode (prints `[usage]` line or nothing, exits 0). `-Refresh` switch reserved (stubbed this task, implemented Task 3). Function `Start-Refresher` stubbed (no-op body this task, implemented Task 4).
- Consumes: live.json shape `{"rate_limits":{"seven_day":{"used_percentage":39,"resets_at":<epoch>},"five_hour":{…}}}`; cache.json shape `{"week_pct":39,"week_resets":"Jul 16, 9:59am","session_pct":32,"session_resets":"Jul 13, 3:29pm","fetched_at":"…"}`.

- [ ] **Step 1: Write the test harness with reading-logic cases**

`tests/test-usage-tier.ps1`:

```powershell
# Plain assertion harness — no Pester. Run: powershell -NoProfile -File tests\test-usage-tier.ps1
$ErrorActionPreference = 'Stop'
$script:Fails = 0
$Hook = Join-Path $PSScriptRoot '..\hooks\usage-tier.ps1'

function Assert-Eq($actual, $expected, $name) {
    if ("$actual" -ceq "$expected") { Write-Host "ok  $name" }
    else { Write-Host "FAIL $name`n  expected: $expected`n  actual:   $actual"; $script:Fails++ }
}

# Fresh temp sandbox per case: sets USAGE_AWARE_DIR/CLAWDOMETER_DIR, disables spawning.
function New-Sandbox {
    $d = Join-Path $env:TEMP ("ua-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force "$d\usage", "$d\claw" | Out-Null
    $env:USAGE_AWARE_DIR = "$d\usage"
    $env:CLAWDOMETER_DIR = "$d\claw"
    $env:USAGE_AWARE_NO_SPAWN = '1'
    Remove-Item Env:USAGE_AWARE_REFRESH -ErrorAction SilentlyContinue
    $d
}

function Write-Live($dir, [int]$weekPct, [double]$ageMinutes) {
    $epoch = [DateTimeOffset]::new((Get-Date).AddDays(2)).ToUnixTimeSeconds()
    $json = '{"rate_limits":{"five_hour":{"used_percentage":32,"resets_at":' + $epoch +
            '},"seven_day":{"used_percentage":' + $weekPct + ',"resets_at":' + $epoch + '}}}'
    $p = Join-Path "$dir\claw" 'live.json'
    Set-Content -Path $p -Value $json -Encoding utf8
    (Get-Item $p).LastWriteTime = (Get-Date).AddMinutes(-$ageMinutes)
}

function Write-Cache($dir, [int]$weekPct, [double]$ageMinutes) {
    $json = '{"week_pct":' + $weekPct + ',"week_resets":"Jul 16, 9:59am","session_pct":32,"session_resets":"Jul 13, 3:29pm"}'
    $p = Join-Path "$dir\usage" 'cache.json'
    Set-Content -Path $p -Value $json -Encoding utf8
    (Get-Item $p).LastWriteTime = (Get-Date).AddMinutes(-$ageMinutes)
}

function Invoke-Hook { (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook) -join "`n" }

# --- tier boundaries (via fresh cache; cache has fixed reset strings) ---
foreach ($case in @(@(59,'normal'), @(60,'frugal'), @(85,'frugal'), @(86,'minimal'))) {
    $d = New-Sandbox
    Write-Cache $d $case[0] 1
    $out = Invoke-Hook
    Assert-Eq $out "[usage] week $($case[0])% · session 32% · week resets Jul 16, 9:59am · tier: $($case[1])" "tier boundary $($case[0])"
}

# --- fresh live beats fresh cache ---
$d = New-Sandbox; Write-Live $d 70 1; Write-Cache $d 10 1
$out = Invoke-Hook
if ($out -match 'week 70% .*tier: frugal' -or $out -match 'week 70%.*tier: frugal') { Write-Host 'ok  live beats cache' }
else { Write-Host "FAIL live beats cache: $out"; $script:Fails++ }

# --- stale live + fresh cache -> cache wins ---
$d = New-Sandbox; Write-Live $d 70 20; Write-Cache $d 10 1
Assert-Eq (Invoke-Hook) '[usage] week 10% · session 32% · week resets Jul 16, 9:59am · tier: normal' 'stale live, fresh cache'

# --- both stale (<24h) -> stale line, no tier ---
$d = New-Sandbox; Write-Cache $d 45 60
Assert-Eq (Invoke-Hook) '[usage] week 45% · session 32% · week resets Jul 16, 9:59am (stale)' 'both stale prints stale, no tier'

# --- both missing -> silence ---
$d = New-Sandbox
Assert-Eq (Invoke-Hook) '' 'missing sources print nothing'

# --- both older than 24h -> silence ---
$d = New-Sandbox; Write-Cache $d 45 1500
Assert-Eq (Invoke-Hook) '' 'over-24h sources print nothing'

# --- malformed live + good cache -> cache used ---
$d = New-Sandbox
Set-Content -Path (Join-Path "$d\claw" 'live.json') -Value '{not json' -Encoding utf8
Write-Cache $d 61 1
Assert-Eq (Invoke-Hook) '[usage] week 61% · session 32% · week resets Jul 16, 9:59am · tier: frugal' 'malformed live falls back to cache'

# --- recursion guard ---
$d = New-Sandbox; Write-Cache $d 45 1
$env:USAGE_AWARE_REFRESH = '1'
$out = Invoke-Hook
Remove-Item Env:USAGE_AWARE_REFRESH -ErrorAction SilentlyContinue
Assert-Eq $out '' 'USAGE_AWARE_REFRESH guard exits silently'

if ($script:Fails -gt 0) { Write-Host "$script:Fails FAILED"; exit 1 }
Write-Host 'all passed'; exit 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell -NoProfile -File tests\test-usage-tier.ps1`
Expected: FAIL (hook script does not exist yet — every `Invoke-Hook` errors or returns empty where output expected).

- [ ] **Step 3: Write `hooks/usage-tier.ps1`**

```powershell
# usage-tier.ps1 — SessionStart hook for the usage-aware skill.
# Hook mode (no args): print one "[usage] ..." line from the freshest source.
# -Refresh: run `claude -p /usage` headlessly and write the cache (Task 3).
# Fails open everywhere: any error -> print nothing, exit 0.
param([switch]$Refresh)

# Recursion guard: this hook fires inside the `claude -p /usage` child the
# refresher spawns. Bail before any file I/O or the refresher forks forever.
if ($env:USAGE_AWARE_REFRESH -eq '1') { exit 0 }

$ErrorActionPreference = 'Stop'

$UsageDir = if ($env:USAGE_AWARE_DIR) { $env:USAGE_AWARE_DIR } else { Join-Path $HOME '.claude\usage-aware' }
$ClawDir  = if ($env:CLAWDOMETER_DIR) { $env:CLAWDOMETER_DIR } else { Join-Path $HOME '.clawdometer' }
$LivePath  = Join-Path $ClawDir 'live.json'
$CachePath = Join-Path $UsageDir 'cache.json'
$LockPath  = Join-Path $UsageDir 'refresh.lock'

function Get-AgeMinutes($path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    ((Get-Date) - (Get-Item -LiteralPath $path).LastWriteTime).TotalMinutes
}

# Epoch seconds -> "Jul 16, 9:59AM" in local time.
function Format-Epoch([int64]$epoch) {
    [DateTimeOffset]::FromUnixTimeSeconds($epoch).ToLocalTime().ToString('MMM d, h:mmtt')
}

# Clawdometer's live.json: rate_limits.{seven_day,five_hour}.{used_percentage,resets_at}
function Read-Live {
    try {
        $j = Get-Content -LiteralPath $LivePath -Raw | ConvertFrom-Json
        $wk = $j.rate_limits.seven_day
        if ($null -eq $wk -or $null -eq $wk.used_percentage) { return $null }
        $sess = $j.rate_limits.five_hour
        $o = [ordered]@{
            week_pct = [int]$wk.used_percentage
            week_resets = Format-Epoch ([int64]$wk.resets_at)
            session_pct = $null; session_resets = $null
        }
        if ($null -ne $sess -and $null -ne $sess.used_percentage) {
            $o.session_pct = [int]$sess.used_percentage
            $o.session_resets = Format-Epoch ([int64]$sess.resets_at)
        }
        [pscustomobject]$o
    } catch { $null }
}

# Our own cache.json: flat week_pct / week_resets / session_pct / session_resets.
function Read-Cache {
    try {
        $j = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json
        if ($null -eq $j.week_pct) { return $null }
        [pscustomobject]@{
            week_pct = [int]$j.week_pct
            week_resets = [string]$j.week_resets
            session_pct = if ($null -ne $j.session_pct) { [int]$j.session_pct } else { $null }
            session_resets = $j.session_resets
        }
    } catch { $null }
}

function Get-Tier([int]$weekPct) {
    if ($weekPct -lt 60) { 'normal' }
    elseif ($weekPct -le 85) { 'frugal' }
    else { 'minimal' }
}

function Format-Line($d, [bool]$stale) {
    $parts = @("week $($d.week_pct)%")
    if ($null -ne $d.session_pct) { $parts += "session $($d.session_pct)%" }
    $parts += "week resets $($d.week_resets)"
    $line = '[usage] ' + ($parts -join ' ' + [char]0xB7 + ' ')
    if ($stale) { "$line (stale)" } else { "$line " + [char]0xB7 + " tier: $(Get-Tier $d.week_pct)" }
}

# Spawn the detached refresher. No-op until Task 4.
function Start-Refresher { }

if ($Refresh) { exit 0 }  # Invoke-Refresh lands in Task 3

try {
    $liveAge = Get-AgeMinutes $LivePath
    $cacheAge = Get-AgeMinutes $CachePath

    if ($null -ne $liveAge -and $liveAge -lt 15) {
        $d = Read-Live
        if ($d) { Format-Line $d $false; exit 0 }
    }
    if ($null -ne $cacheAge -and $cacheAge -lt 10) {
        $d = Read-Cache
        if ($d) { Format-Line $d $false; exit 0 }
    }

    # Both stale or missing: kick a background refresh, show stale numbers if
    # they're under 24h old, otherwise stay silent.
    Start-Refresher
    $d = $null
    if ($null -ne $liveAge -and $liveAge -lt 1440) { $d = Read-Live }
    if ($null -eq $d -and $null -ne $cacheAge -and $cacheAge -lt 1440) { $d = Read-Cache }
    if ($d) { Format-Line $d $true }
} catch { }
exit 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `powershell -NoProfile -File tests\test-usage-tier.ps1`
Expected: `all passed`, exit 0. If the `·` renders wrong, check both files are saved UTF-8 and the harness compares with `-ceq` on identical encodings.

- [ ] **Step 5: Commit**

```bash
git add hooks/usage-tier.ps1 tests/test-usage-tier.ps1
git commit -m "feat(usage-aware): hook reading logic with tier computation, fail-open"
```

---

### Task 3: Refresher mode (`-Refresh`)

**Files:**
- Modify: `hooks/usage-tier.ps1` (replace the `if ($Refresh) { exit 0 }` stub)
- Test: `tests/test-usage-tier.ps1` (append cases)

**Interfaces:**
- Consumes: `report.txt` fixture (Task 1); `$CachePath`, `$LockPath`, `$UsageDir` variables (Task 2).
- Produces: `Invoke-Refresh` function: runs `claude -p --no-session-persistence /usage` via cmd.exe with `USAGE_AWARE_REFRESH=1` set, 60 s timeout with tree-kill, parses week/session lines, writes `cache.json` atomically (`.tmp` + rename). Task 4 spawns it.

- [ ] **Step 1: Append refresher tests to the harness** (before the final `if ($script:Fails…` block)

```powershell
# Fake `claude` on PATH: a .cmd shim that types a canned report.
function Install-FakeClaude($dir, $reportPath) {
    $bin = Join-Path $dir 'bin'
    New-Item -ItemType Directory -Force $bin | Out-Null
    Set-Content -Path (Join-Path $bin 'claude.cmd') -Encoding ascii -Value "@echo off`r`ntype `"$reportPath`""
    $env:PATH = "$bin;$env:PATH"
}

$Fixture = Join-Path $PSScriptRoot 'fixtures\report.txt'

# --- refresher writes cache from the fixture report ---
$d = New-Sandbox
$savedPath = $env:PATH
Install-FakeClaude $d $Fixture
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook -Refresh
$env:PATH = $savedPath
$cache = Get-Content (Join-Path "$d\usage" 'cache.json') -Raw | ConvertFrom-Json
Assert-Eq $cache.week_pct 39 'refresher: week_pct parsed'
Assert-Eq $cache.session_pct 32 'refresher: session_pct parsed'
Assert-Eq $cache.week_resets 'Jul 16, 9:59am' 'refresher: week reset string verbatim'
Assert-Eq (Test-Path (Join-Path "$d\usage" 'cache.json.tmp')) 'False' 'refresher: no tmp file left behind'

# --- refresher on garbage output leaves old cache intact ---
$d = New-Sandbox
Write-Cache $d 45 60
$garbage = Join-Path "$d\usage" 'garbage.txt'
Set-Content -Path $garbage -Value 'Rate limits are unavailable right now' -Encoding utf8
$savedPath = $env:PATH
Install-FakeClaude $d $garbage
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook -Refresh
$env:PATH = $savedPath
$cache = Get-Content (Join-Path "$d\usage" 'cache.json') -Raw | ConvertFrom-Json
Assert-Eq $cache.week_pct 45 'refresher: garbage output keeps old cache'
```

- [ ] **Step 2: Run to verify new cases fail**

Run: `powershell -NoProfile -File tests\test-usage-tier.ps1`
Expected: earlier cases pass; the two refresher cases FAIL (no cache.json written — `-Refresh` is still a stub).

- [ ] **Step 3: Implement `Invoke-Refresh`** — replace `if ($Refresh) { exit 0 }` with:

```powershell
# Headless refresh: let the official CLI fetch the numbers with its own
# credentials; we only parse the text it prints and cache two lines of it.
function Invoke-Refresh {
    New-Item -ItemType Directory -Force $UsageDir | Out-Null
    Set-Content -LiteralPath $LockPath -Value $PID -Encoding ascii
    $outFile = Join-Path $UsageDir 'refresh-out.txt'
    # The claude child fires this same hook on ITS startup; the guard env var
    # (inherited cmd -> claude -> hook) makes that invocation exit instantly.
    $env:USAGE_AWARE_REFRESH = '1'
    $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $p = Start-Process -FilePath $cmdExe `
        -ArgumentList '/C', 'claude -p --no-session-persistence /usage' `
        -NoNewWindow -PassThru -RedirectStandardOutput $outFile
    if (-not $p.WaitForExit(60000)) {
        # cmd.exe wrapper means claude is a grandchild — kill the whole tree,
        # or hung fetches pile up one per refresh (Clawdometer learned this).
        $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        & $taskkill /PID $p.Id /T /F | Out-Null
        return
    }
    $text = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
    if (-not $text) { return }
    $week = [regex]::Match($text, '(?m)^\s*Current week \(all models\): (\d+)% used.*?resets ([^(]+?)\s*\(')
    if (-not $week.Success) { return }  # wording changed or fetch failed: keep old cache
    $sess = [regex]::Match($text, '(?m)^\s*Current session: (\d+)% used.*?resets ([^(]+?)\s*\(')
    $cache = [ordered]@{
        fetched_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        week_pct = [int]$week.Groups[1].Value
        week_resets = $week.Groups[2].Value.Trim()
    }
    if ($sess.Success) {
        $cache['session_pct'] = [int]$sess.Groups[1].Value
        $cache['session_resets'] = $sess.Groups[2].Value.Trim()
    }
    $tmp = "$CachePath.tmp"
    Set-Content -LiteralPath $tmp -Value (([pscustomobject]$cache) | ConvertTo-Json) -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $CachePath -Force
}

if ($Refresh) { try { Invoke-Refresh } catch { } exit 0 }
```

- [ ] **Step 4: Run tests to verify all pass**

Run: `powershell -NoProfile -File tests\test-usage-tier.ps1`
Expected: `all passed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add hooks/usage-tier.ps1 tests/test-usage-tier.ps1
git commit -m "feat(usage-aware): headless /usage refresher with atomic cache write"
```

---

### Task 4: Spawn wiring + lockfile gate

**Files:**
- Modify: `hooks/usage-tier.ps1` (fill the `Start-Refresher` no-op)
- Test: `tests/test-usage-tier.ps1` (append cases)

**Interfaces:**
- Consumes: `Invoke-Refresh` (Task 3), `Start-Refresher` stub call-site in the stale/missing path (Task 2).
- Produces: detached hidden refresher spawn, gated by `USAGE_AWARE_NO_SPAWN` and a 5-minute lockfile.

- [ ] **Step 1: Append spawn tests** (before the final fail-check block)

```powershell
# --- stale sources spawn the refresher, which fills the cache (end to end) ---
$d = New-Sandbox
Remove-Item Env:USAGE_AWARE_NO_SPAWN -ErrorAction SilentlyContinue
$savedPath = $env:PATH
Install-FakeClaude $d $Fixture
Invoke-Hook | Out-Null   # both sources missing -> silent, but must spawn
$deadline = (Get-Date).AddSeconds(15)
while (-not (Test-Path (Join-Path "$d\usage" 'cache.json')) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
}
$env:PATH = $savedPath
$env:USAGE_AWARE_NO_SPAWN = '1'
Assert-Eq (Test-Path (Join-Path "$d\usage" 'refresh.lock')) 'True' 'spawn: lockfile written'
Assert-Eq (Test-Path (Join-Path "$d\usage" 'cache.json')) 'True' 'spawn: detached refresher filled cache'

# --- fresh lockfile suppresses a second spawn ---
$d = New-Sandbox
Remove-Item Env:USAGE_AWARE_NO_SPAWN -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$d\usage" | Out-Null
Set-Content -Path (Join-Path "$d\usage" 'refresh.lock') -Value '12345' -Encoding ascii
$before = (Get-Item (Join-Path "$d\usage" 'refresh.lock')).LastWriteTime
Invoke-Hook | Out-Null
Start-Sleep -Seconds 2
$env:USAGE_AWARE_NO_SPAWN = '1'
$after = (Get-Item (Join-Path "$d\usage" 'refresh.lock')).LastWriteTime
Assert-Eq $after $before 'fresh lockfile blocks respawn'
Assert-Eq (Test-Path (Join-Path "$d\usage" 'cache.json')) 'False' 'blocked spawn wrote no cache'
```

- [ ] **Step 2: Run to verify new cases fail**

Run: `powershell -NoProfile -File tests\test-usage-tier.ps1`
Expected: `spawn: lockfile written` and `spawn: detached refresher filled cache` FAIL (Start-Refresher is a no-op).

- [ ] **Step 3: Implement `Start-Refresher`** — replace the no-op:

```powershell
# Fire-and-forget hidden refresher. The hook must never block session start
# on the network, so the refresh happens in a detached process; THIS session
# gets stale-or-nothing and the NEXT one reads the fresh cache.
function Start-Refresher {
    if ($env:USAGE_AWARE_NO_SPAWN -eq '1') { return }
    $lockAge = Get-AgeMinutes $LockPath
    if ($null -ne $lockAge -and $lockAge -lt 5) { return }  # one in flight (or just failed) — don't pile up
    New-Item -ItemType Directory -Force $UsageDir | Out-Null
    Set-Content -LiteralPath $LockPath -Value $PID -Encoding ascii
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Refresh' `
        -WindowStyle Hidden
}
```

Note: the parent does NOT set `USAGE_AWARE_REFRESH` here — the refresher itself must pass the guard. Only `Invoke-Refresh` sets it, for its `claude` child.

- [ ] **Step 4: Run full suite**

Run: `powershell -NoProfile -File tests\test-usage-tier.ps1`
Expected: `all passed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add hooks/usage-tier.ps1 tests/test-usage-tier.ps1
git commit -m "feat(usage-aware): detached refresher spawn with lockfile pile-up guard"
```

---

### Task 5: POSIX port (`usage-tier.sh`)

**Files:**
- Create: `hooks/usage-tier.sh`
- Test: `tests/test-usage-tier.sh`

**Interfaces:**
- Consumes: same file shapes and env overrides as the ps1 (Global Constraints).
- Produces: `usage-tier.sh` (hook mode / `--refresh`), byte-identical `[usage]` output format.

Freshness via `find -mmin` (GNU and BSD both support it). JSON extraction via `sed` on the known shapes — no jq dependency. Run tests under Git Bash on this machine.

- [ ] **Step 1: Write the sh test harness**

`tests/test-usage-tier.sh`:

```sh
#!/bin/sh
# Run: sh tests/test-usage-tier.sh   (Git Bash / any POSIX sh)
HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/usage-tier.sh"
FIXTURE="$(cd "$(dirname "$0")" && pwd)/fixtures/report.txt"
FAILS=0

assert_eq() { # actual expected name
    if [ "$1" = "$2" ]; then echo "ok  $3"
    else echo "FAIL $3"; echo "  expected: $2"; echo "  actual:   $1"; FAILS=$((FAILS+1)); fi
}

sandbox() {
    D="$(mktemp -d)"
    mkdir -p "$D/usage" "$D/claw"
    export USAGE_AWARE_DIR="$D/usage" CLAWDOMETER_DIR="$D/claw" USAGE_AWARE_NO_SPAWN=1
    unset USAGE_AWARE_REFRESH
}

write_live() { # week_pct age_minutes
    epoch=$(( $(date +%s) + 172800 ))
    printf '{"rate_limits":{"five_hour":{"used_percentage":32,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
        "$epoch" "$1" "$epoch" > "$D/claw/live.json"
    touch_age "$D/claw/live.json" "$2"
}

write_cache() { # week_pct age_minutes
    printf '{"week_pct":%s,"week_resets":"Jul 16, 9:59am","session_pct":32,"session_resets":"Jul 13, 3:29pm"}' \
        "$1" > "$D/usage/cache.json"
    touch_age "$D/usage/cache.json" "$2"
}

touch_age() { # file age_minutes  (backdate mtime)
    ts=$(( $(date +%s) - $2 * 60 ))
    if date -d "@$ts" '+%Y%m%d%H%M.%S' >/dev/null 2>&1; then
        touch -t "$(date -d "@$ts" '+%Y%m%d%H%M.%S')" "$1"   # GNU
    else
        touch -t "$(date -r "$ts" '+%Y%m%d%H%M.%S')" "$1"    # BSD
    fi
}

MID=$(printf '\302\267')  # U+00B7 in UTF-8

# tier boundaries via fresh cache
for case in "59 normal" "60 frugal" "85 frugal" "86 minimal"; do
    pct=${case% *}; tier=${case#* }
    sandbox; write_cache "$pct" 1
    out="$(sh "$HOOK")"
    assert_eq "$out" "[usage] week ${pct}% ${MID} session 32% ${MID} week resets Jul 16, 9:59am ${MID} tier: ${tier}" "tier boundary $pct"
done

# stale live + fresh cache -> cache
sandbox; write_live 70 20; write_cache 10 1
assert_eq "$(sh "$HOOK")" "[usage] week 10% ${MID} session 32% ${MID} week resets Jul 16, 9:59am ${MID} tier: normal" "stale live, fresh cache"

# both stale -> stale line, no tier
sandbox; write_cache 45 60
assert_eq "$(sh "$HOOK")" "[usage] week 45% ${MID} session 32% ${MID} week resets Jul 16, 9:59am (stale)" "stale line no tier"

# missing -> silence
sandbox
assert_eq "$(sh "$HOOK")" "" "missing sources silent"

# guard
sandbox; write_cache 45 1
USAGE_AWARE_REFRESH=1 out="$(sh "$HOOK")"
assert_eq "$out" "" "refresh guard silent"

# refresher parses fixture into cache
sandbox
mkdir -p "$D/bin"
printf '#!/bin/sh\ncat "%s"\n' "$FIXTURE" > "$D/bin/claude"
chmod +x "$D/bin/claude"
PATH="$D/bin:$PATH" sh "$HOOK" --refresh
grep -q '"week_pct": *39' "$D/usage/cache.json" && echo "ok  refresher week_pct" || { echo "FAIL refresher week_pct"; FAILS=$((FAILS+1)); }
grep -q '"session_pct": *32' "$D/usage/cache.json" && echo "ok  refresher session_pct" || { echo "FAIL refresher session_pct"; FAILS=$((FAILS+1)); }

[ "$FAILS" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$FAILS FAILED"; exit 1
```

- [ ] **Step 2: Run to verify it fails** — `sh tests/test-usage-tier.sh` → FAIL (hook missing).

- [ ] **Step 3: Write `hooks/usage-tier.sh`**

```sh
#!/bin/sh
# usage-tier.sh — SessionStart hook for the usage-aware skill (POSIX port of
# usage-tier.ps1; same sources, same output format, fails open everywhere).

[ "$USAGE_AWARE_REFRESH" = "1" ] && exit 0

USAGE_DIR="${USAGE_AWARE_DIR:-$HOME/.claude/usage-aware}"
CLAW_DIR="${CLAWDOMETER_DIR:-$HOME/.clawdometer}"
LIVE="$CLAW_DIR/live.json"
CACHE="$USAGE_DIR/cache.json"
LOCK="$USAGE_DIR/refresh.lock"
MID=$(printf '\302\267')

fresh() { # file max_age_minutes -> 0 if exists and newer
    [ -f "$1" ] && [ -n "$(find "$1" -mmin "-$2" 2>/dev/null)" ]
}

json_num() { # file key -> first "key":<int> match
    sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -n1
}

json_str() { # file key -> first "key":"..." match
    sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -n1
}

fmt_epoch() { # epoch -> "Jul 16, 9:59AM" local time (GNU then BSD date)
    date -d "@$1" '+%b %-d, %-I:%M%p' 2>/dev/null || date -r "$1" '+%b %-d, %-I:%M%p' 2>/dev/null
}

# read_live/read_cache set: WEEK_PCT WEEK_RESETS SESSION_PCT SESSION_RESETS
read_live() {
    seven=$(sed -n 's/.*"seven_day"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' "$LIVE" 2>/dev/null)
    [ -n "$seven" ] || return 1
    WEEK_PCT=$(printf '%s' "$seven" | sed -n 's/.*"used_percentage"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    [ -n "$WEEK_PCT" ] || return 1
    epoch=$(printf '%s' "$seven" | sed -n 's/.*"resets_at"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    WEEK_RESETS=$(fmt_epoch "$epoch")
    five=$(sed -n 's/.*"five_hour"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' "$LIVE" 2>/dev/null)
    SESSION_PCT=$(printf '%s' "$five" | sed -n 's/.*"used_percentage"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    if [ -n "$SESSION_PCT" ]; then
        sepoch=$(printf '%s' "$five" | sed -n 's/.*"resets_at"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
        SESSION_RESETS=$(fmt_epoch "$sepoch")
    fi
    return 0
}

read_cache() {
    WEEK_PCT=$(json_num "$CACHE" week_pct)
    [ -n "$WEEK_PCT" ] || return 1
    WEEK_RESETS=$(json_str "$CACHE" week_resets)
    SESSION_PCT=$(json_num "$CACHE" session_pct)
    SESSION_RESETS=$(json_str "$CACHE" session_resets)
    return 0
}

tier() {
    if [ "$1" -lt 60 ]; then echo normal
    elif [ "$1" -le 85 ]; then echo frugal
    else echo minimal; fi
}

print_line() { # $1 = "fresh" | "stale"
    line="[usage] week ${WEEK_PCT}%"
    [ -n "$SESSION_PCT" ] && line="$line ${MID} session ${SESSION_PCT}%"
    line="$line ${MID} week resets ${WEEK_RESETS}"
    if [ "$1" = "stale" ]; then echo "$line (stale)"
    else echo "$line ${MID} tier: $(tier "$WEEK_PCT")"; fi
}

do_refresh() {
    mkdir -p "$USAGE_DIR"
    echo $$ > "$LOCK"
    out="$USAGE_DIR/refresh-out.txt"
    # Guard env inherits into claude's own SessionStart hook run.
    USAGE_AWARE_REFRESH=1 claude -p --no-session-persistence /usage > "$out" 2>/dev/null &
    pid=$!
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 1; i=$((i+1)); done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; return; fi
    week_line=$(grep 'Current week (all models):' "$out" 2>/dev/null | head -n1)
    [ -n "$week_line" ] || return
    wp=$(printf '%s' "$week_line" | sed -n 's/.*: \([0-9][0-9]*\)% used.*/\1/p')
    wr=$(printf '%s' "$week_line" | sed -n 's/.*resets \(.*\) (.*/\1/p')
    [ -n "$wp" ] || return
    sess_line=$(grep 'Current session:' "$out" 2>/dev/null | head -n1)
    sp=$(printf '%s' "$sess_line" | sed -n 's/.*: \([0-9][0-9]*\)% used.*/\1/p')
    sr=$(printf '%s' "$sess_line" | sed -n 's/.*resets \(.*\) (.*/\1/p')
    {
        printf '{"fetched_at":"%s","week_pct":%s,"week_resets":"%s"' \
            "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$wp" "$wr"
        [ -n "$sp" ] && printf ',"session_pct":%s,"session_resets":"%s"' "$sp" "$sr"
        printf '}\n'
    } > "$CACHE.tmp"
    mv -f "$CACHE.tmp" "$CACHE"
}

spawn_refresher() {
    [ "$USAGE_AWARE_NO_SPAWN" = "1" ] && return
    fresh "$LOCK" 5 && return
    mkdir -p "$USAGE_DIR"
    echo $$ > "$LOCK"
    nohup sh "$0" --refresh >/dev/null 2>&1 &
}

if [ "$1" = "--refresh" ]; then do_refresh; exit 0; fi

if fresh "$LIVE" 15 && read_live; then print_line fresh; exit 0; fi
if fresh "$CACHE" 10 && read_cache; then print_line fresh; exit 0; fi

spawn_refresher
if fresh "$LIVE" 1440 && read_live; then print_line stale
elif fresh "$CACHE" 1440 && read_cache; then print_line stale
fi
exit 0
```

Note on the sh test's `refresher session_pct`: sh cache JSON has no space after `:`, the grep patterns use `: *` so both spacings pass.

- [ ] **Step 4: Run** — `sh tests/test-usage-tier.sh` → `all passed`.

- [ ] **Step 5: Commit**

```bash
git add hooks/usage-tier.sh tests/test-usage-tier.sh
git commit -m "feat(usage-aware): POSIX hook port with sh test harness"
```

---

### Task 6: Installer (`install.ps1`)

**Files:**
- Create: `install.ps1`
- Test: `tests/test-install.ps1`

**Interfaces:**
- Consumes: `SKILL.md`, `hooks/usage-tier.ps1`.
- Produces: files under `~/.claude/`, `SessionStart` entry merged into `settings.json`. Honors `USAGE_AWARE_INSTALL_ROOT` override for tests (defaults to `$HOME\.claude`).

- [ ] **Step 1: Write installer test**

`tests/test-install.ps1`:

```powershell
$ErrorActionPreference = 'Stop'
$script:Fails = 0
$Installer = Join-Path $PSScriptRoot '..\install.ps1'

function Assert-True($cond, $name) {
    if ($cond) { Write-Host "ok  $name" } else { Write-Host "FAIL $name"; $script:Fails++ }
}

# --- install into empty root: creates settings.json with hook entry ---
$root = Join-Path $env:TEMP ("ua-inst-" + [guid]::NewGuid().ToString('N'))
$env:USAGE_AWARE_INSTALL_ROOT = $root
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Installer
$settings = Get-Content (Join-Path $root 'settings.json') -Raw | ConvertFrom-Json
$cmds = @($settings.hooks.SessionStart | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
Assert-True (($cmds -join ' ') -match 'usage-tier\.ps1') 'empty root: hook command registered'
Assert-True (Test-Path (Join-Path $root 'skills\usage-aware\SKILL.md')) 'empty root: SKILL.md installed'
Assert-True (Test-Path (Join-Path $root 'hooks\usage-tier.ps1')) 'empty root: hook script installed'

# --- idempotent: second run adds no duplicate ---
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Installer
$settings = Get-Content (Join-Path $root 'settings.json') -Raw | ConvertFrom-Json
$cmds = @($settings.hooks.SessionStart | ForEach-Object { $_.hooks } | ForEach-Object { $_.command }) -match 'usage-tier'
Assert-True ($cmds.Count -eq 1) 'second run: no duplicate hook entry'

# --- merge preserves existing settings and hooks ---
$root = Join-Path $env:TEMP ("ua-inst-" + [guid]::NewGuid().ToString('N'))
$env:USAGE_AWARE_INSTALL_ROOT = $root
New-Item -ItemType Directory -Force $root | Out-Null
Set-Content -Path (Join-Path $root 'settings.json') -Encoding utf8 -Value @'
{"model":"opus","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}
'@
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Installer
$settings = Get-Content (Join-Path $root 'settings.json') -Raw | ConvertFrom-Json
Assert-True ($settings.model -eq 'opus') 'merge: unrelated key preserved'
$cmds = @($settings.hooks.SessionStart | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
Assert-True (($cmds -contains 'echo hi') -and (($cmds -join ' ') -match 'usage-tier')) 'merge: old hook kept, new added'
Assert-True ((Get-ChildItem $root -Filter 'settings.json.bak-*').Count -ge 1) 'merge: backup written'

Remove-Item Env:USAGE_AWARE_INSTALL_ROOT -ErrorAction SilentlyContinue
if ($script:Fails -gt 0) { Write-Host "$script:Fails FAILED"; exit 1 }
Write-Host 'all passed'; exit 0
```

- [ ] **Step 2: Run to verify it fails** — installer missing.

- [ ] **Step 3: Write `install.ps1`**

```powershell
# Installs the usage-aware skill + SessionStart hook into ~/.claude (or
# USAGE_AWARE_INSTALL_ROOT for tests). Additive settings.json merge; a
# timestamped backup is written before any modification.
$ErrorActionPreference = 'Stop'

$Root = if ($env:USAGE_AWARE_INSTALL_ROOT) { $env:USAGE_AWARE_INSTALL_ROOT } else { Join-Path $HOME '.claude' }
$Src = $PSScriptRoot

$skillDir = Join-Path $Root 'skills\usage-aware'
$hooksDir = Join-Path $Root 'hooks'
New-Item -ItemType Directory -Force $skillDir, $hooksDir | Out-Null
Copy-Item (Join-Path $Src 'SKILL.md') (Join-Path $skillDir 'SKILL.md') -Force
Copy-Item (Join-Path $Src 'hooks\usage-tier.ps1') (Join-Path $hooksDir 'usage-tier.ps1') -Force

$hookPath = Join-Path $hooksDir 'usage-tier.ps1'
$hookCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$hookPath`""

$settingsPath = Join-Path $Root 'settings.json'
if (Test-Path $settingsPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item $settingsPath "$settingsPath.bak-$stamp"
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
} else {
    $settings = [pscustomobject]@{}
}

if ($null -eq $settings.PSObject.Properties['hooks']) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
}
if ($null -eq $settings.hooks.PSObject.Properties['SessionStart']) {
    $settings.hooks | Add-Member -NotePropertyName SessionStart -NotePropertyValue @()
}

$existing = @($settings.hooks.SessionStart) |
    ForEach-Object { $_.hooks } | ForEach-Object { $_.command } |
    Where-Object { $_ -match 'usage-tier\.ps1' }
if (-not $existing) {
    $entry = [pscustomobject]@{
        hooks = @([pscustomobject]@{ type = 'command'; command = $hookCmd })
    }
    $settings.hooks.SessionStart = @($settings.hooks.SessionStart) + $entry
}

Set-Content -Path $settingsPath -Value ($settings | ConvertTo-Json -Depth 20) -Encoding utf8
Write-Host "usage-aware installed. Hook: $hookCmd"
Write-Host "Restart Claude Code sessions to pick it up."
```

- [ ] **Step 4: Run** — `powershell -NoProfile -File tests\test-install.ps1` → `all passed`.

- [ ] **Step 5: Commit**

```bash
git add install.ps1 tests/test-install.ps1
git commit -m "feat(usage-aware): installer with additive settings.json merge"
```

---

### Task 7: README + live smoke test

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Write `README.md`** — cover: what it does (one paragraph), the `[usage]` line format, tier table (copy from SKILL.md), install (`powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1`), data sources (Clawdometer live.json first, own cache second, background `claude -p /usage` third), uninstall (delete `~/.claude/skills/usage-aware`, `~/.claude/hooks/usage-tier.ps1`, remove the SessionStart entry from `settings.json`, delete `~/.claude/usage-aware/`), and a Troubleshooting note: no line at session start means both sources were missing/stale — the first session primes the cache, the second shows the line.

- [ ] **Step 2: Run both test suites clean**

```bash
powershell -NoProfile -File tests/test-usage-tier.ps1
powershell -NoProfile -File tests/test-install.ps1
sh tests/test-usage-tier.sh
```
Expected: `all passed` ×3.

- [ ] **Step 3: Live smoke (real machine, real claude)** — do NOT fake anything here:

```powershell
# 1. Refresher against the real CLI (uses the account's real /usage):
powershell -NoProfile -ExecutionPolicy Bypass -File hooks\usage-tier.ps1 -Refresh
Get-Content "$HOME\.claude\usage-aware\cache.json"
# expect real week_pct/session_pct values

# 2. Hook line:
powershell -NoProfile -ExecutionPolicy Bypass -File hooks\usage-tier.ps1
# expect: [usage] week N% · session N% · week resets <date> · tier: <tier>
```

If step 1 writes no cache: run `claude -p --no-session-persistence /usage` manually and compare its output against the regexes (CLI wording may have changed since v2.1.207 — if so, update both regexes AND `tests/fixtures/report.txt` from the real output).

- [ ] **Step 4: Install for real + verify** — run `install.ps1` (no env override), start a new `claude` session, confirm the `[usage]` line appears in context (ask Claude "what does your [usage] line say?").

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs(usage-aware): README with install, sources, uninstall"
```

---

## Self-Review Notes

- Spec coverage: sources/priority (T2), refresher+guards+atomic write (T3–T4), tiers+SKILL rules (T1), POSIX (T5), installer merge+backup (T6), smoke (T7). Reset-time math intentionally absent (out of scope — verbatim strings; epoch formatting only for live.json display).
- Known judgment call: ps1 output uses `[char]0xB7` and the sh port `printf '\302\267'` so neither script file needs non-ASCII bytes — avoids PS 5.1 codepage mangling of literal `·` in .ps1 files saved without BOM.
- Type consistency: cache keys `week_pct/week_resets/session_pct/session_resets` identical across ps1 writer (T3), ps1 reader (T2), sh writer/reader (T5), and test fixtures.


