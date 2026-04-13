# claude-statusline installer for Windows
# Run: powershell -NoProfile -File install.ps1

$ErrorActionPreference = 'Stop'

$srcScript = Join-Path $PSScriptRoot 'statusline.ps1'
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$dstScript = Join-Path $claudeDir 'statusline.ps1'
$settingsFile = Join-Path $claudeDir 'settings.local.json'

# --- Copy script ---
if (-not (Test-Path $claudeDir)) {
    Write-Host "Error: $claudeDir does not exist. Is Claude Code installed?" -ForegroundColor Red
    exit 1
}

Copy-Item $srcScript $dstScript -Force
Write-Host "Copied statusline.ps1 -> $dstScript" -ForegroundColor Green

# --- Update settings.local.json ---
$cmdPath = ($dstScript -replace '\\', '/')

if (Test-Path $settingsFile) {
    $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
} else {
    $settings = [PSCustomObject]@{}
}

# Set statusLine config
$statusLine = [PSCustomObject]@{
    type    = 'command'
    command = "powershell -NoProfile -File $cmdPath"
    padding = 1
}
if ($settings.PSObject.Properties['statusLine']) {
    $settings.statusLine = $statusLine
} else {
    $settings | Add-Member -NotePropertyName 'statusLine' -NotePropertyValue $statusLine
}

# Ensure permissions.allow contains the script
$permEntry = 'Bash(~/.claude/statusline.ps1)'
if (-not $settings.PSObject.Properties['permissions']) {
    $settings | Add-Member -NotePropertyName 'permissions' -NotePropertyValue ([PSCustomObject]@{
        allow = @($permEntry)
    })
} elseif (-not $settings.permissions.PSObject.Properties['allow']) {
    $settings.permissions | Add-Member -NotePropertyName 'allow' -NotePropertyValue @($permEntry)
} else {
    $allowList = @($settings.permissions.allow)
    if ($permEntry -notin $allowList) {
        $allowList += $permEntry
        $settings.permissions.allow = $allowList
    }
}

$settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
Write-Host "Updated $settingsFile" -ForegroundColor Green
Write-Host ''
Write-Host 'Done! Restart Claude Code to see the new statusline.' -ForegroundColor Cyan
