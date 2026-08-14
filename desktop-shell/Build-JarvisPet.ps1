[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceFile = Join-Path $scriptRoot 'JarvisPet.cs'
$distDirectory = Join-Path $scriptRoot 'dist'
$outputFile = Join-Path $distDirectory 'JarvisPet.exe'

if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'JARVIS Pet requires 64-bit Windows.'
}

if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
    throw "Source file not found: $sourceFile"
}

$compilerPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compilerPath -PathType Leaf)) {
    throw "System x64 C# compiler not found: $compilerPath"
}

$programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
if ([string]::IsNullOrWhiteSpace($programFilesX86)) {
    $programFilesX86 = $env:ProgramFiles
}

$referenceRoot = Join-Path $programFilesX86 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8'
if (-not (Test-Path -LiteralPath $referenceRoot -PathType Container)) {
    throw ".NET Framework 4.8 reference assemblies not found: $referenceRoot"
}

$referenceNames = @(
    'mscorlib.dll',
    'System.dll',
    'System.Core.dll',
    'System.Net.Http.dll',
    'System.Speech.dll',
    'System.Web.Extensions.dll',
    'WindowsBase.dll',
    'PresentationCore.dll',
    'PresentationFramework.dll',
    'System.Xaml.dll'
)

$references = foreach ($name in $referenceNames) {
    $path = Join-Path $referenceRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required .NET Framework 4.8 assembly not found: $path"
    }

    $path
}

New-Item -ItemType Directory -Path $distDirectory -Force | Out-Null

$arguments = @(
    '/nologo',
    '/noconfig',
    '/nostdlib+',
    '/target:winexe',
    '/platform:x64',
    '/optimize+',
    '/debug-',
    '/warn:4',
    "/out:$outputFile"
)

foreach ($reference in $references) {
    $arguments += "/reference:$reference"
}

$arguments += $sourceFile
& $compilerPath @arguments
if ($LASTEXITCODE -ne 0) {
    throw "JARVIS Pet compilation failed with exit code $LASTEXITCODE."
}

if (-not (Test-Path -LiteralPath $outputFile -PathType Leaf)) {
    throw "Compiler reported success but output is missing: $outputFile"
}

Write-Host "Built x64 JARVIS Pet: $outputFile"
