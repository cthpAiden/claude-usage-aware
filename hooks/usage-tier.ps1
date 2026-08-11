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
