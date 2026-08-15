Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Jarvis.PrivateChannel.psm1') -Force -ErrorAction Stop

function Test-JarvisSubscription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LicensePath,
        [Parameter(Mandatory)][string]$InstallId,
        [string]$PublicKeyPath = (Join-Path $PSScriptRoot 'public-key.xml'),
        [string]$PinnedPublicKeyFingerprint
    )

    if (-not (Test-Path -LiteralPath $LicensePath -PathType Leaf)) { throw 'Subscription licence file is missing: ' + $LicensePath }
    $arguments = @{
        ExpectedKind = 'license'
        EnvelopePath = $LicensePath
        InstallId = $InstallId
        PublicKeyPath = $PublicKeyPath
    }
    if (-not [string]::IsNullOrWhiteSpace($PinnedPublicKeyFingerprint)) {
        $arguments.PinnedPublicKeyFingerprint = $PinnedPublicKeyFingerprint
    }
    try {
        $verified = Test-JarvisSignedEnvelope @arguments
    } catch {
        throw 'Subscription verification failed: ' + $_.Exception.Message
    }
    return [pscustomobject]@{
        Licensed = $true
        Tier = [string]$verified.Tier
        LicenseId = [string]$verified.LicenseId
        ExpiresAt = $verified.ExpiresAt
        Features = @($verified.Features)
    }
}

function Test-JarvisSubscriptionFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LicensePath)
    return (Test-Path -LiteralPath $LicensePath -PathType Leaf)
}

Export-ModuleMember -Function Test-JarvisSubscription, Test-JarvisSubscriptionFile
