[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$errors = [System.Collections.Generic.List[string]]::new()
foreach ($name in @('Build-Installer-FINAL-v2.ps1', 'Install-Jarvis-RELEASE.ps1', 'Start-Jarvis-RELEASE.ps1')) {
    $path = Join-Path $root $name
    $tokens = $null; $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    foreach ($error in $parseErrors) { $errors.Add("$name line $($error.Extent.StartLineNumber): $($error.Message)") }
}
if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) { $errors.Add('Node.js was not found.') }
if (-not (Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\iexpress.exe') -PathType Leaf)) { $errors.Add('IExpress was not found.') }
if ($errors.Count) { $errors | ForEach-Object { Write-Error $_ }; exit 1 }
Write-Host 'JARVIS NEXUS FINAL installer preflight passed.' -ForegroundColor Cyan
