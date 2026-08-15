<#
.SYNOPSIS
  Minimal opt-in updater UI: a small topmost WinForms dialog that shows the
  current version, the new version and optional release notes, with
  «Обновить» / «Отмена» buttons. UI-only; it never calls the updater.

.EXAMPLE
  $go = & .\Show-JarvisUpdatePrompt.ps1 -CurrentVersion 1.0.0 -NewVersion 9.9.9 -ReleaseNotes "Исправления и улучшения"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CurrentVersion,
    [Parameter(Mandatory)][string]$NewVersion,
    [string]$ReleaseNotes = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

$form = New-Object System.Windows.Forms.Form
$form.Text = 'JARVIS NEXUS ULTRA — обновление'
$form.Size = New-Object System.Drawing.Size(460, 320)
$form.StartPosition = 'CenterScreen'
$form.TopMost = $true
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$header = New-Object System.Windows.Forms.Label
$header.Text = "Доступно обновление: $CurrentVersion → $NewVersion"
$header.Location = New-Object System.Drawing.Point(16, 16)
$header.AutoSize = $true
$header.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)

$notesLabel = New-Object System.Windows.Forms.Label
$notesLabel.Text = 'Что нового:'
$notesLabel.Location = New-Object System.Drawing.Point(16, 52)
$notesLabel.AutoSize = $true

$notes = New-Object System.Windows.Forms.TextBox
$notes.Location = New-Object System.Drawing.Point(16, 76)
$notes.Size = New-Object System.Drawing.Size(416, 150)
$notes.Multiline = $true
$notes.ReadOnly = $true
$notes.ScrollBars = 'Vertical'
$notes.Text = $ReleaseNotes

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = 'Отмена'
$cancelButton.Size = New-Object System.Drawing.Size(104, 28)
$cancelButton.Location = New-Object System.Drawing.Point(328, 240)
$cancelButton.DialogResult = 'Cancel'

$updateButton = New-Object System.Windows.Forms.Button
$updateButton.Text = 'Обновить'
$updateButton.Size = New-Object System.Drawing.Size(104, 28)
$updateButton.Location = New-Object System.Drawing.Point(216, 240)
$updateButton.DialogResult = 'OK'

$form.AcceptButton = $updateButton
$form.CancelButton = $cancelButton
$form.Controls.Add($header)
$form.Controls.Add($notesLabel)
$form.Controls.Add($notes)
$form.Controls.Add($cancelButton)
$form.Controls.Add($updateButton)

try {
    $result = $form.ShowDialog()
    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
} finally {
    $form.Dispose()
}
