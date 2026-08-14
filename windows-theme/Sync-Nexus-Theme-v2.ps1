<#
.SYNOPSIS
  Compatibility adapter for legacy JARVIS theme commands.

.DESCRIPTION
  Existing JARVIS builds call Sync-Nexus-Theme.ps1. This adapter routes Apply
  to the verified durable wallpaper module and refuses an unsafe blind restore.
#>
[CmdletBinding()]
param(
    [ValidateSet('Apply', 'Restore')]
    [string]$Mode = 'Apply'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Mode -eq 'Restore') {
    throw 'Automatic theme restore is disabled in this build to keep a durable wallpaper path. Change the theme in Windows Settings if you want a different look.'
}

$safeModule = Join-Path $PSScriptRoot 'Enable-Nexus-Desktop.ps1'
if (-not (Test-Path -LiteralPath $safeModule -PathType Leaf)) { throw "Safe NEXUS desktop module is missing: $safeModule" }
& $safeModule -Mode Apply
$nativeExit = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
if ($null -ne $nativeExit -and [int]$nativeExit.Value -ne 0) { throw "NEXUS desktop module stopped with code $($nativeExit.Value)." }
