<#
.SYNOPSIS
  Progress HUD for a JARVIS update: a small topmost window with a progress bar,
  the percentage and the estimated remaining time. It reads its state from a
  JSON status file written by Invoke-JarvisUpdate.ps1 and closes automatically
  when the update finishes (or fails).

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Show-JarvisUpdateProgress.ps1 -StatusFile C:\...\update-progress.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StatusFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

$form = New-Object System.Windows.Forms.Form
$form.Text = 'JARVIS — обновление'
$form.Size = New-Object System.Drawing.Size(470, 170)
$form.StartPosition = 'CenterScreen'
$form.TopMost = $true
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$title = New-Object System.Windows.Forms.Label
$title.Location = New-Object System.Drawing.Point(16, 14)
$title.Size = New-Object System.Drawing.Size(430, 24)
$title.Text = 'Обновление JARVIS...'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location = New-Object System.Drawing.Point(16, 46)
$bar.Size = New-Object System.Drawing.Size(430, 26)
$bar.Minimum = 0
$bar.Maximum = 100
$bar.Style = 'Blocks'

$detail = New-Object System.Windows.Forms.Label
$detail.Location = New-Object System.Drawing.Point(16, 84)
$detail.Size = New-Object System.Drawing.Size(430, 44)
$detail.Text = 'Скачивание...'

$form.Controls.Add($title)
$form.Controls.Add($bar)
$form.Controls.Add($detail)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200

function Format-Remaining([int]$Seconds) {
    if ($Seconds -le 0) { return 'осталось: считаем...' }
    if ($Seconds -lt 90) { return "осталось: примерно $Seconds сек." }
    if ($Seconds -lt 5400) { return "осталось: примерно $([math]::Ceiling($Seconds / 60)) мин." }
    return "осталось: примерно $([math]::Round($Seconds / 3600, 1)) ч."
}

$timer.Add_Tick({
    try {
        if (-not (Test-Path -LiteralPath $StatusFile -PathType Leaf)) { return }
        $state = Get-Content -LiteralPath $StatusFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $bar.Value = [int][math]::Min(100, [math]::Max(0, [int]$state.Percent))
        $remaining = Format-Remaining ([int]$state.RemainingSeconds)
        switch ([string]$state.State) {
            'downloading' {
                $title.Text = "Обновление до версии $($state.Version)"
                $detail.Text = "Скачивание: $($state.Percent)%`n$remaining"
            }
            'installing' {
                $title.Text = "Обновление до версии $($state.Version)"
                $detail.Text = 'Установка обновления...'
                $bar.Style = 'Marquee'
                $bar.MarqueeAnimationSpeed = 25
            }
            'done' {
                $title.Text = 'Готово'
                $detail.Text = "JARVIS обновлён до версии $($state.Version)."
                $bar.Value = 100
                $bar.Style = 'Blocks'
                $timer.Stop()
                $form.Close()
            }
            'error' {
                $title.Text = 'Ошибка обновления'
                $detail.Text = [string]$state.Message
                $bar.Style = 'Blocks'
                $timer.Stop()
                $form.Close()
            }
        }
    } catch {
        # The status file may be mid-write; retry on the next tick.
    }
})

$timer.Start()
[System.Windows.Forms.Application]::Run($form)
