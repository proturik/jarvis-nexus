[CmdletBinding()]
param([string]$WorkRoot = 'C:\tmp\jarvis-nexus-iexpress')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$installerRoot = $PSScriptRoot
$errors = [System.Collections.Generic.List[string]]::new()
foreach ($name in @('Build-Installer-RELEASE-v2.ps1', 'Install-Jarvis-RELEASE.ps1', 'Start-Jarvis-RELEASE.ps1')) {
    $path = Join-Path $installerRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $errors.Add("Missing $name"); continue }
    $tokens = $null; $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    foreach ($parseError in $parseErrors) { $errors.Add("$name line $($parseError.Extent.StartLineNumber): $($parseError.Message)") }
}
foreach ($name in @('Install-Jarvis-RELEASE.cmd', 'Start-Jarvis-RELEASE.cmd')) { if (-not (Test-Path -LiteralPath (Join-Path $installerRoot $name) -PathType Leaf)) { $errors.Add("Missing $name") } }
if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) { $errors.Add('Node.js was not found.') }
if (-not (Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\iexpress.exe') -PathType Leaf)) { $errors.Add('IExpress was not found.') }
if ([System.IO.Path]::GetFullPath($WorkRoot) -match '\s|[^\x20-\x7E]') { $errors.Add('WorkRoot must be ASCII and contain no spaces.') }
if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Error $_ }; exit 1 }
Write-Host 'JARVIS NEXUS RELEASE v2 installer preflight passed.' -ForegroundColor Cyan
