[CmdletBinding()]
param(
    [string]$NodeRuntime,
    [string]$IExpressWorkRoot = (Join-Path $PSScriptRoot 'build-ultra')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$errors = [System.Collections.Generic.List[string]]::new()
$installerRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent $installerRoot

function Add-CheckError {
    param([string]$Message)
    $errors.Add($Message)
}

function Check-Path {
    param([string]$Path, [string]$Label, [bool]$Directory)
    $exists = if ($Directory) {
        Test-Path -LiteralPath $Path -PathType Container
    }
    else {
        Test-Path -LiteralPath $Path -PathType Leaf
    }
    if (-not $exists) {
        Add-CheckError "Missing $($Label): $Path"
    }
}

function Check-PowerShellSyntax {
    param([string]$Path)
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    foreach ($parseError in $parseErrors) {
        Add-CheckError "Syntax error in $(Split-Path -Leaf $Path), line $($parseError.Extent.StartLineNumber): $($parseError.Message)"
    }
}

foreach ($file in @(
    'Build-Installer-ULTRA.ps1',
    'Install-Jarvis-ULTRA.ps1',
    'Install-Jarvis-ULTRA.cmd',
    'Start-Jarvis-ULTRA.ps1',
    'Start-Jarvis-ULTRA.cmd'
)) {
    $path = Join-Path $installerRoot $file
    Check-Path -Path $path -Label 'ULTRA installer file' -Directory $false
    if ($file.EndsWith('.ps1') -and (Test-Path -LiteralPath $path -PathType Leaf)) {
        Check-PowerShellSyntax $path
    }
}

foreach ($file in @('package.json', 'ultra-server.mjs')) {
    Check-Path -Path (Join-Path $projectRoot $file) -Label "ULTRA app file $file" -Directory $false
}
foreach ($directory in @('public-ultra', 'assets', 'windows-control', 'windows-theme')) {
    Check-Path -Path (Join-Path $projectRoot $directory) -Label "ULTRA app directory $directory" -Directory $true
}

$iexpress = @(
    (Join-Path $env:WINDIR 'System32\iexpress.exe'),
    (Join-Path $env:WINDIR 'SysWOW64\iexpress.exe')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $iexpress) {
    Add-CheckError 'IExpress was not found in Windows.'
}

$resolvedWorkRoot = [System.IO.Path]::GetFullPath($IExpressWorkRoot)
if ($resolvedWorkRoot -match '\s' -or $resolvedWorkRoot -match '[^\x20-\x7E]') {
    Add-CheckError "IExpressWorkRoot must use ASCII and contain no spaces: $resolvedWorkRoot"
}

$nodeCandidates = [System.Collections.Generic.List[string]]::new()
if ($NodeRuntime) {
    $nodeCandidates.Add($NodeRuntime)
}
$vendoredNode = Join-Path $projectRoot 'runtime\node.exe'
if (Test-Path -LiteralPath $vendoredNode -PathType Leaf) {
    $nodeCandidates.Add($vendoredNode)
}
$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $nodeCommand) {
    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
}
if ($null -ne $nodeCommand -and $nodeCommand.Source) {
    $nodeCandidates.Add($nodeCommand.Source)
}

$node = $nodeCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $node) {
    Add-CheckError 'Node.js 20+ was not found. Supply -NodeRuntime with a local node.exe.'
}
else {
    $reportedVersion = (& $node --version 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $reportedVersion -notmatch '^v(?<major>\d+)\.') {
        Add-CheckError "Unable to run Node runtime: $node"
    }
    elseif ([int]$Matches.major -lt 20) {
        Add-CheckError "Node.js 20+ is required; found $reportedVersion."
    }
}

if ($errors.Count -gt 0) {
    Write-Host 'JARVIS NEXUS ULTRA installer preflight failed:' -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host 'JARVIS NEXUS ULTRA installer preflight passed.' -ForegroundColor Cyan
Write-Host "IExpress: $iexpress"
Write-Host "Node:     $node ($reportedVersion)"
Write-Host "Stage:    $resolvedWorkRoot"
Write-Host 'No EXE was built and no files were changed.'
