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
