# Pester runner for the statusline test suite.
# Usage: powershell -NoProfile -File tests\run.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# OneDrive redirection of MyDocuments puts user modules at a path that
# $env:PSModulePath doesn't always include. Add it explicitly so
# Install-Module-installed Pester 5+ is discoverable.
$myDocsModules = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
if ((Test-Path $myDocsModules) -and (-not ($env:PSModulePath -split [System.IO.Path]::PathSeparator | Where-Object { $_ -eq $myDocsModules }))) {
    $env:PSModulePath = $myDocsModules + [System.IO.Path]::PathSeparator + $env:PSModulePath
}

$pester = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    Write-Host "Pester is not installed. Install with: Install-Module Pester -Scope CurrentUser -Force" -ForegroundColor Red
    exit 2
}
if ($pester.Version.Major -lt 5) {
    Write-Host "Pester $($pester.Version) detected; this suite requires Pester 5+." -ForegroundColor Red
    Write-Host "Install with: Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck" -ForegroundColor Yellow
    exit 2
}

Import-Module Pester -MinimumVersion 5.0.0 -Force

$config = New-PesterConfiguration
$config.Run.Path = (Join-Path $PSScriptRoot 'statusline.Tests.ps1')
$config.Output.Verbosity = 'Detailed'
$config.Run.Exit = $true

Invoke-Pester -Configuration $config
