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

function Invoke-Hook {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Hook
    @{ output = ($out -join "`n"); exit_code = $LASTEXITCODE }
}

function Assert-HookOutput($result, $expectedOutput, $name) {
    $actualOutput = $result.output
    $actualExitCode = $result.exit_code
    if ("$actualOutput" -ceq "$expectedOutput" -and $actualExitCode -eq 0) {
        Write-Host "ok  $name"
    } else {
        Write-Host "FAIL $name`n  expected output: $expectedOutput`n  actual output:   $actualOutput`n  exit code: $actualExitCode"
        $script:Fails++
    }
}

# --- tier boundaries (via fresh cache; cache has fixed reset strings) ---
$dot = [char]0xB7
foreach ($case in @(@(59,'normal'), @(60,'frugal'), @(85,'frugal'), @(86,'minimal'))) {
    $d = New-Sandbox
    Write-Cache $d $case[0] 1
    $result = Invoke-Hook
    Assert-HookOutput $result "[usage] week $($case[0])% $dot session 32% $dot week resets Jul 16, 9:59am $dot tier: $($case[1])" "tier boundary $($case[0])"
}

# --- fresh live beats fresh cache ---
$d = New-Sandbox; Write-Live $d 70 1; Write-Cache $d 10 1
$result = Invoke-Hook
if (($result.output -match 'week 70% .*tier: frugal' -or $result.output -match 'week 70%.*tier: frugal') -and $result.exit_code -eq 0) { Write-Host 'ok  live beats cache' }
else { Write-Host "FAIL live beats cache: $($result.output) exit_code: $($result.exit_code)"; $script:Fails++ }

# --- stale live + fresh cache -> cache wins ---
$d = New-Sandbox; Write-Live $d 70 20; Write-Cache $d 10 1
$result = Invoke-Hook
Assert-HookOutput $result "[usage] week 10% $dot session 32% $dot week resets Jul 16, 9:59am $dot tier: normal" 'stale live, fresh cache'

# --- both stale (<24h) -> stale line, no tier ---
$d = New-Sandbox; Write-Cache $d 45 60
$result = Invoke-Hook
Assert-HookOutput $result "[usage] week 45% $dot session 32% $dot week resets Jul 16, 9:59am (stale)" 'both stale prints stale, no tier'

# --- both missing -> silence ---
$d = New-Sandbox
$result = Invoke-Hook
Assert-HookOutput $result '' 'missing sources print nothing'

# --- both older than 24h -> silence ---
$d = New-Sandbox; Write-Cache $d 45 1500
$result = Invoke-Hook
Assert-HookOutput $result '' 'over-24h sources print nothing'

# --- malformed live + good cache -> cache used ---
$d = New-Sandbox
Set-Content -Path (Join-Path "$d\claw" 'live.json') -Value '{not json' -Encoding utf8
Write-Cache $d 61 1
$result = Invoke-Hook
Assert-HookOutput $result "[usage] week 61% $dot session 32% $dot week resets Jul 16, 9:59am $dot tier: frugal" 'malformed live falls back to cache'

# --- recursion guard ---
$d = New-Sandbox; Write-Cache $d 45 1
$env:USAGE_AWARE_REFRESH = '1'
$result = Invoke-Hook
Remove-Item Env:USAGE_AWARE_REFRESH -ErrorAction SilentlyContinue
Assert-HookOutput $result '' 'USAGE_AWARE_REFRESH guard exits silently'

if ($script:Fails -gt 0) { Write-Host "$script:Fails FAILED"; exit 1 }
Write-Host 'all passed'; exit 0
