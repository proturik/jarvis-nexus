<#
.SYNOPSIS
  Neat update prompt for JARVIS NEXUS ULTRA: shows the current version, the new
  version, the download size and optional release notes, with an accent
  «Обновить сейчас» button and a «Позже» button.

.DESCRIPTION
  UI-only: it returns $true (update) or $false (later) and never calls the
  updater. The caller runs the actual download + install with the progress HUD.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CurrentVersion,
    [Parameter(Mandatory)][string]$NewVersion,
    [string]$ReleaseNotes = '',
    [long]$PackageBytes = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

$accent = [System.Drawing.Color]::FromArgb(0, 142, 204)
$darkText = [System.Drawing.Color]::FromArgb(32, 32, 32)
$mutedText = [System.Drawing.Color]::FromArgb(110, 110, 110)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'JARVIS NEXUS ULTRA'
$form.Size = New-Object System.Drawing.Size(480, 360)
$form.StartPosition = 'CenterScreen'
$form.TopMost = $true
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor = [System.Drawing.Color]::White

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Доступно обновление JARVIS'
$title.Location = New-Object System.Drawing.Point(18, 16)
$title.AutoSize = $true
$title.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = $darkText

$versions = New-Object System.Windows.Forms.Label
$versions.Text = "Текущая версия: $CurrentVersion"
$versions.Location = New-Object System.Drawing.Point(18, 54)
$versions.AutoSize = $true
$versions.ForeColor = $mutedText

$newVersion = New-Object System.Windows.Forms.Label
$newVersion.Text = "Новая версия: $NewVersion"
$newVersion.Location = New-Object System.Drawing.Point(18, 76)
$newVersion.AutoSize = $true
$newVersion.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$newVersion.ForeColor = $accent

$sizeText = if ($PackageBytes -gt 0) { "Размер обновления: $([math]::Round($PackageBytes / 1MB, 1)) МБ" } else { 'Размер обновления: определяется при скачивании' }
$sizeLabel = New-Object System.Windows.Forms.Label
$sizeLabel.Text = $sizeText
$sizeLabel.Location = New-Object System.Drawing.Point(18, 100)
$sizeLabel.AutoSize = $true
$sizeLabel.ForeColor = $mutedText

$notes = New-Object System.Windows.Forms.TextBox
$notes.Location = New-Object System.Drawing.Point(18, 132)
$notes.Size = New-Object System.Drawing.Size(440, 150)
$notes.Multiline = $true
$notes.ReadOnly = $true
$notes.ScrollBars = 'Vertical'
$notes.BorderStyle = 'FixedSingle'
$notes.BackColor = [System.Drawing.Color]::FromArgb(248, 248, 248)
if ([string]::IsNullOrWhiteSpace($ReleaseNotes)) {
    $notes.Text = 'Новая версия готова. JARVIS скачает и установит её автоматически — с прогрессом и откатом при ошибке.'
} else {
    $notes.Text = $ReleaseNotes
}

$updateButton = New-Object System.Windows.Forms.Button
$updateButton.Text = 'Обновить сейчас'
$updateButton.Size = New-Object System.Drawing.Size(180, 40)
$updateButton.Location = New-Object System.Drawing.Point(278, 296)
$updateButton.BackColor = $accent
$updateButton.ForeColor = [System.Drawing.Color]::White
$updateButton.FlatStyle = 'Flat'
$updateButton.FlatAppearance.BorderSize = 0
$updateButton.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$updateButton.DialogResult = 'OK'
$updateButton.Cursor = [System.Windows.Forms.Cursors]::Hand

$laterButton = New-Object System.Windows.Forms.Button
$laterButton.Text = 'Позже'
$laterButton.Size = New-Object System.Drawing.Size(120, 40)
$laterButton.Location = New-Object System.Drawing.Point(152, 296)
$laterButton.FlatStyle = 'Flat'
$laterButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
$laterButton.ForeColor = $mutedText
$laterButton.DialogResult = 'Cancel'

$form.AcceptButton = $updateButton
$form.CancelButton = $laterButton
$form.Controls.Add($title)
$form.Controls.Add($versions)
$form.Controls.Add($newVersion)
$form.Controls.Add($sizeLabel)
$form.Controls.Add($notes)
$form.Controls.Add($updateButton)
$form.Controls.Add($laterButton)

try {
    $result = $form.ShowDialog()
    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
} finally {
    $form.Dispose()
}
