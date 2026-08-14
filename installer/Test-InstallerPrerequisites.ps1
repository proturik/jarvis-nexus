[CmdletBinding()]
param(
    [string]$NodeRuntime,
    [string]$IExpressWorkRoot = (Join-Path $PSScriptRoot 'build')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$installerRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent $installerRoot

function Add-Error {
    param([string]$Message)
    $errors.Add($Message)
}

function Test-RequiredPath {
    param([string]$Path, [string]$Label, [bool]$Directory)
    $exists = if ($Directory) {
        Test-Path -LiteralPath $Path -PathType Container
    }
    else {
        Test-Path -LiteralPath $Path -PathType Leaf
    }
    if (-not $exists) {
        Add-Error "Missing $Label: $Path"
    }
}

function Test-PowerShellSyntax {
    param([string]$Path)
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    foreach ($parseError in $parseErrors) {
        Add-Error "PowerShell syntax error in $(Split-Path -Leaf $Path), line $($parseError.Extent.StartLineNumber): $($parseError.Message)"
    }
}

foreach ($path in @(
    (Join-Path $installerRoot 'Build-Installer.ps1'),
    (Join-Path $installerRoot 'Install-Jarvis.ps1'),
    (Join-Path $installerRoot 'Install-Jarvis.cmd'),
    (Join-Path $installerRoot 'Start-Jarvis.ps1'),
    (Join-Path $installerRoot 'Start-Jarvis.cmd')
)) {
    Test-RequiredPath -Path $path -Label 'installer file' -Directory $false
    if ($path.EndsWith('.ps1') -and (Test-Path -LiteralPath $path -PathType Leaf)) {
        Test-PowerShellSyntax $path
    }
}

foreach ($file in @('package.json', 'ultra-server.mjs')) {
    Test-RequiredPath -Path (Join-Path $projectRoot $file) -Label "app file $file" -Directory $false
}
foreach ($directory in @('public-ultra', 'assets', 'windows-control', 'windows-theme')) {
    Test-RequiredPath -Path (Join-Path $projectRoot $directory) -Label "app directory $directory" -Directory $true
}

$iexpress = @(
    (Join-Path $env:WINDIR 'System32\iexpress.exe'),
    (Join-Path $env:WINDIR 'SysWOW64\iexpress.exe')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $iexpress) {
    Add-Error 'IExpress was not found in Windows.'
}

$resolvedWorkRoot = [System.IO.Path]::GetFullPath($IExpressWorkRoot)
if ($resolvedWorkRoot -match '\s' -or $resolvedWorkRoot -match '[^\x20-\x7E]') {
    Add-Error "IExpressWorkRoot must use ASCII and contain no spaces: $resolvedWorkRoot"
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
    Add-Error 'Node.js 20+ was not found. Supply -NodeRuntime with a local node.exe.'
}
else {
    $reportedVersion = (& $node --version 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $reportedVersion -notmatch '^v(?<major>\d+)\.') {
        Add-Error "Unable to run Node runtime: $node"
    }
    elseif ([int]$Matches.major -lt 20) {
        Add-Error "Node.js 20+ is required; found $reportedVersion."
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
Write-Host 'No installer was built and no files were changed.'
