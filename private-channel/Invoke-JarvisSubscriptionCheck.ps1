<#
.SYNOPSIS
  Client-side gate the launcher runs before starting JARVIS. It resolves (or
  creates) the install ID, verifies the tier-aware subscription licence and
  either prints a short summary (exit 0) or shows a topmost «Требуется
  подписка JARVIS» dialog and exits 1.

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Invoke-JarvisSubscriptionCheck.ps1 -InstallRoot C:\JARVIS\app-current
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallRoot,
    [string]$DataRoot = (Join-Path $InstallRoot '..\data'),
    [string]$PublicKeyPath = (Join-Path $PSScriptRoot 'public-key.xml'),
    [string]$PurchaseUrl = 'https://proturik.github.io/jarvis-nexus/purchase.html'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Jarvis.Subscription.psm1') -Force -ErrorAction Stop

function Show-SubscriptionRequiredDialog {
    param([Parameter(Mandatory)][string]$PurchaseUrl)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Требуется подписка JARVIS'
    $form.Size = New-Object System.Drawing.Size(500, 250)
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $message = New-Object System.Windows.Forms.Label
    $message.Location = New-Object System.Drawing.Point(16, 16)
    $message.Size = New-Object System.Drawing.Size(460, 140)
    $message.Text = "Для использования JARVIS NEXUS требуется активная подписка.`r`n`r`nПробный период завершён, лицензия не найдена или недействительна.`r`nОформите подписку и поместите файл лицензии в папку license внутри каталога данных.`r`n`r`nАдрес оформления подписки:`r`n$PurchaseUrl"

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'OK'
    $okButton.Size = New-Object System.Drawing.Size(104, 28)
    $okButton.Location = New-Object System.Drawing.Point(372, 172)
    $okButton.DialogResult = 'OK'

    $form.AcceptButton = $okButton
    $form.CancelButton = $okButton
    $form.Controls.Add($message)
    $form.Controls.Add($okButton)

    try {
        $null = $form.ShowDialog()
    } finally {
        $form.Dispose()
    }
}

$resolvedDataRoot = [IO.Path]::GetFullPath($DataRoot)
$installIdPath = Join-Path $resolvedDataRoot 'install-id.txt'
$licensePath = Join-Path $resolvedDataRoot 'license\license.json'

$installId = ''
if (Test-Path -LiteralPath $installIdPath -PathType Leaf) {
    $installId = (Get-Content -LiteralPath $installIdPath -Raw -Encoding UTF8).Trim()
}
if ([string]::IsNullOrWhiteSpace($installId)) {
    $installId = 'install-' + [Guid]::NewGuid().ToString('N')
    New-Item -ItemType Directory -Path $resolvedDataRoot -Force | Out-Null
    [IO.File]::WriteAllText($installIdPath, $installId, (New-Object Text.UTF8Encoding($false)))
}

$subscription = $null
try {
    $subscription = Test-JarvisSubscription -LicensePath $licensePath -InstallId $installId -PublicKeyPath $PublicKeyPath
} catch {
    $subscription = $null
}

if ($null -eq $subscription) {
    Show-SubscriptionRequiredDialog -PurchaseUrl $PurchaseUrl
    exit 1
}

$featureList = @($subscription.Features) -join ','
Write-Output ("JARVIS subscription active: tier=$($subscription.Tier) licenseId=$($subscription.LicenseId) expiresAt=$($subscription.ExpiresAt) features=$featureList")
exit 0
