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
