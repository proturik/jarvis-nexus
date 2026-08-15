<#
.SYNOPSIS
  Owner-side convenience wrapper around New-JarvisSignedEnvelope.ps1 for
  issuing tier-aware subscription licences (monthly / yearly / lifetime).

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\New-JarvisSubscriptionLicense.ps1 `
      -InstallId install-PASTE_RANDOM_INSTALL_ID -Tier yearly -LicenseId sub-yearly-001 -OutputPath .\license-yearly.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$InstallId,
    [ValidateSet('monthly', 'yearly', 'lifetime')][string]$Tier = 'lifetime',
    [string]$LicenseId = ('license-' + [Guid]::NewGuid().ToString('N')),
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$KeyRoot = (Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA\owner-secrets'),
    [string[]]$Feature = @('core', 'voice', 'vision')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$arguments = @{
    Kind = 'license'
    OutputPath = $OutputPath
    KeyRoot = $KeyRoot
    InstallId = $InstallId
    LicenseId = $LicenseId
    Feature = $Feature
    Tier = $Tier
}

& (Join-Path $PSScriptRoot 'New-JarvisSignedEnvelope.ps1') @arguments
