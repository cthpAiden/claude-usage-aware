# usage-tier.ps1 — SessionStart hook for the usage-aware skill.
# Hook mode (no args): print one "[usage] ..." line from the freshest source.
# -Refresh: run `claude -p /usage` headlessly and write the cache (Task 3).
# Fails open everywhere: any error -> print nothing, exit 0.
param([switch]$Refresh)

# Recursion guard: this hook fires inside the `claude -p /usage` child the
# refresher spawns. Bail before any file I/O or the refresher forks forever.
if ($env:USAGE_AWARE_REFRESH -eq '1') { exit 0 }

$ErrorActionPreference = 'Stop'

$UsageDir = $null
$ClawDir = $null
$LivePath = $null
$CachePath = $null
$LockPath = $null

try {
    $UsageDir = if ($env:USAGE_AWARE_DIR) { $env:USAGE_AWARE_DIR } else { Join-Path $HOME '.claude\usage-aware' }
    $ClawDir  = if ($env:CLAWDOMETER_DIR) { $env:CLAWDOMETER_DIR } else { Join-Path $HOME '.clawdometer' }
    $LivePath  = Join-Path $ClawDir 'live.json'
    $CachePath = Join-Path $UsageDir 'cache.json'
    $LockPath  = Join-Path $UsageDir 'refresh.lock'
} catch { exit 0 }

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
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Refresh' `
        -WindowStyle Hidden
}

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
    if (Test-Path -LiteralPath $CachePath) {
        [System.IO.File]::Replace($tmp, $CachePath, $null)
    } else {
        Move-Item -LiteralPath $tmp -Destination $CachePath
    }
}

if ($Refresh) { try { Invoke-Refresh } catch { } exit 0 }

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
