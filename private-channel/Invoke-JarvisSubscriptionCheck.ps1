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
    param([Parameter(Mandatory)][string]$PurchaseUrl, [Parameter(Mandatory)][string]$InstallId)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Требуется подписка JARVIS'
    $form.Size = New-Object System.Drawing.Size(520, 340)
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $message = New-Object System.Windows.Forms.Label
    $message.Location = New-Object System.Drawing.Point(16, 12)
    $message.Size = New-Object System.Drawing.Size(488, 110)
    $message.Text = "JARVIS NEXUS требует активную подписку.`r`n`r`n1. Скопируйте ваш код установки ниже и отправьте его владельцу.`r`n2. Полученный файл лицензии положите в папку license каталога данных JARVIS.`r`n3. Снова запустите JARVIS."

    $idLabel = New-Object System.Windows.Forms.Label
    $idLabel.Text = 'Ваш код установки:'
    $idLabel.Location = New-Object System.Drawing.Point(16, 126)
    $idLabel.AutoSize = $true

    $idBox = New-Object System.Windows.Forms.TextBox
    $idBox.Text = $InstallId
    $idBox.Location = New-Object System.Drawing.Point(16, 148)
    $idBox.Size = New-Object System.Drawing.Size(488, 22)
    $idBox.ReadOnly = $true
    $idBox.Font = New-Object System.Drawing.Font('Consolas', 9)

    $copyButton = New-Object System.Windows.Forms.Button
    $copyButton.Text = 'Скопировать код'
    $copyButton.Size = New-Object System.Drawing.Size(140, 28)
    $copyButton.Location = New-Object System.Drawing.Point(16, 178)
    $copyButton.Add_Click({
        try {
            [System.Windows.Forms.Clipboard]::SetText($InstallId)
            $copyButton.Text = 'Скопировано!'
        } catch {
            $copyButton.Text = 'Выделите и Ctrl+C'
        }
    })

    $licenseLabel = New-Object System.Windows.Forms.Label
    $licenseLabel.Location = New-Object System.Drawing.Point(16, 216)
    $licenseLabel.Size = New-Object System.Drawing.Size(488, 44)
    $licenseLabel.Text = "Каталог данных: %LOCALAPPDATA%\JARVIS NEXUS ULTRA\data`r`nЛицензия: data\license\license.json"

    $purchaseLink = New-Object System.Windows.Forms.LinkLabel
    $purchaseLink.Text = $PurchaseUrl
    $purchaseLink.Location = New-Object System.Drawing.Point(16, 266)
    $purchaseLink.Size = New-Object System.Drawing.Size(488, 20)
    $purchaseLink.Add_Click({ [System.Diagnostics.Process]::Start($PurchaseUrl) })

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'OK'
    $okButton.Size = New-Object System.Drawing.Size(104, 28)
    $okButton.Location = New-Object System.Drawing.Point(400, 262)
    $okButton.DialogResult = 'OK'

    $form.AcceptButton = $okButton
    $form.CancelButton = $okButton
    $form.Controls.Add($message)
    $form.Controls.Add($idLabel)
    $form.Controls.Add($idBox)
    $form.Controls.Add($copyButton)
    $form.Controls.Add($licenseLabel)
    $form.Controls.Add($purchaseLink)
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
    Show-SubscriptionRequiredDialog -PurchaseUrl $PurchaseUrl -InstallId $installId
    exit 1
}

$featureList = @($subscription.Features) -join ','
Write-Output ("JARVIS subscription active: tier=$($subscription.Tier) licenseId=$($subscription.LicenseId) expiresAt=$($subscription.ExpiresAt) features=$featureList")
exit 0
