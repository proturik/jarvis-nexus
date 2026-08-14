<#!
.SYNOPSIS
  Делает один локальный снимок экрана для опционального визуального контура JARVIS.

.DESCRIPTION
  Этот файл не отправляет изображение в сеть и не делает запись экрана.
  Он создаёт ровно один JPEG по пути, который передал локальный сервер NEXUS.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [ValidateSet('Primary', 'Virtual')]
    [string]$Target = 'Primary',

    [ValidateRange(640, 1920)]
    [int]$MaxWidth = 1280,

    [ValidateRange(45, 90)]
    [int]$JpegQuality = 72
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try {
    $bounds = if ($Target -eq 'Virtual') { [System.Windows.Forms.SystemInformation]::VirtualScreen } else { [System.Windows.Forms.Screen]::PrimaryScreen.Bounds }
    if ($bounds.Width -lt 1 -or $bounds.Height -lt 1) { throw 'Windows did not report a valid screen size.' }

    $source = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [System.Drawing.Graphics]::FromImage($source)
    $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size, [System.Drawing.CopyPixelOperation]::SourceCopy)
    $graphics.Dispose()

    $scale = [Math]::Min(1.0, $MaxWidth / [double]$bounds.Width)
    $outputWidth = [Math]::Max(1, [int][Math]::Round($bounds.Width * $scale))
    $outputHeight = [Math]::Max(1, [int][Math]::Round($bounds.Height * $scale))
    $output = [System.Drawing.Bitmap]::new($outputWidth, $outputHeight, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $resizer = [System.Drawing.Graphics]::FromImage($output)
    $resizer.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $resizer.DrawImage($source, 0, 0, $outputWidth, $outputHeight)
    $resizer.Dispose()
    $source.Dispose()

    $directory = Split-Path -Parent $OutputPath
    if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
    $parameters = [System.Drawing.Imaging.EncoderParameters]::new(1)
    $parameters.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new([System.Drawing.Imaging.Encoder]::Quality, [int64]$JpegQuality)
    $output.Save($OutputPath, $codec, $parameters)
    $output.Dispose()
    $parameters.Dispose()

    [pscustomobject]@{ ok = $true; path = $OutputPath; width = $outputWidth; height = $outputHeight; capturedAt = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json -Compress
}
catch {
    [pscustomobject]@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
    exit 1
}
