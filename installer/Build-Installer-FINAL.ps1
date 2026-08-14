[CmdletBinding()]
param(
    [string]$NodeRuntime,
    [string]$OutputPath,
    [string]$WorkRoot = 'C:\tmp\jarvis-nexus-iexpress'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $projectRoot = Split-Path -Parent $PSScriptRoot
    $OutputPath = Join-Path $projectRoot 'release\JARVIS-NEXUS-ULTRA-Setup.exe'
}

$engine = Join-Path $PSScriptRoot 'Build-Installer-RELEASE-v2.ps1'
if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) { throw "Build engine not found: $engine" }
& $engine -NodeRuntime $NodeRuntime -OutputPath $OutputPath -WorkRoot $WorkRoot
exit $LASTEXITCODE
