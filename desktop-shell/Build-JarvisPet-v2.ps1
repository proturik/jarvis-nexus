[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceFile = Join-Path $scriptRoot 'JarvisPet.cs'
$distDirectory = Join-Path $scriptRoot 'dist'
$patchedSource = Join-Path $distDirectory 'JarvisPet.build.cs'
$outputFile = Join-Path $distDirectory 'JarvisPet.exe'
$iconFile = Join-Path $scriptRoot 'assets\jarvis-nexus.ico'
$coreImageFile = Join-Path $scriptRoot 'assets\jarvis-nexus-core.png'

if (-not [Environment]::Is64BitOperatingSystem) { throw 'JARVIS Pet requires 64-bit Windows.' }
if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) { throw "Source file not found: $sourceFile" }
if (-not (Test-Path -LiteralPath $iconFile -PathType Leaf)) { throw "Application icon not found: $iconFile" }
if (-not (Test-Path -LiteralPath $coreImageFile -PathType Leaf)) { throw "Core image not found: $coreImageFile" }

$compilerPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compilerPath -PathType Leaf)) { throw "System x64 C# compiler not found: $compilerPath" }

$programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
if ([string]::IsNullOrWhiteSpace($programFilesX86)) { $programFilesX86 = $env:ProgramFiles }
$referenceRoot = Join-Path $programFilesX86 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8'
$runtimeRoot = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$wpfRuntimeRoot = Join-Path $runtimeRoot 'WPF'
$useReferenceAssemblies = Test-Path -LiteralPath $referenceRoot -PathType Container
if (-not $useReferenceAssemblies -and -not (Test-Path -LiteralPath $wpfRuntimeRoot -PathType Container)) {
    throw 'Neither .NET Framework 4.8 reference assemblies nor the Windows WPF runtime were found.'
}

$referenceNames = @(
    'mscorlib.dll', 'System.dll', 'System.Core.dll', 'System.Net.Http.dll', 'System.Speech.dll',
    'System.Web.Extensions.dll', 'WindowsBase.dll', 'PresentationCore.dll', 'PresentationFramework.dll', 'System.Xaml.dll'
)
$references = foreach ($name in $referenceNames) {
    $candidates = if ($useReferenceAssemblies) {
        @( (Join-Path $referenceRoot $name) )
    } else {
        @( (Join-Path $runtimeRoot $name), (Join-Path $wpfRuntimeRoot $name) )
    }
    $path = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($path)) { throw "Required assembly not found: $name" }
    $path
}

New-Item -ItemType Directory -Path $distDirectory -Force | Out-Null
$sourceText = [System.IO.File]::ReadAllText($sourceFile, [System.Text.UTF8Encoding]::new($false))
$layoutNeedle = '            root.Children.Add(shell);'
$layoutReplacement = "            Grid.SetColumnSpan(shell, 2);`r`n            root.Children.Add(shell);"
if (-not $sourceText.Contains($layoutNeedle)) { throw 'Pet layout patch anchor not found.' }
$sourceText = $sourceText.Replace($layoutNeedle, $layoutReplacement)
$panelNeedle = '            Width = _panelOpen ? ExpandedWidth : CompactWidth;'
$panelReplacement = "            Width = _panelOpen ? ExpandedWidth : CompactWidth;`r`n`r`n            var workArea = SystemParameters.WorkArea;`r`n            Left = Math.Max(workArea.Left + 16, Math.Min(Left, workArea.Right - Width - 28));"
if (-not $sourceText.Contains($panelNeedle)) { throw 'Pet window clamp patch anchor not found.' }
$sourceText = $sourceText.Replace($panelNeedle, $panelReplacement)
[System.IO.File]::WriteAllText($patchedSource, $sourceText, [System.Text.UTF8Encoding]::new($false))

$arguments = @('/nologo', '/noconfig', '/nostdlib+', '/target:winexe', '/platform:x64', '/optimize+', '/debug-', '/warn:4', "/win32icon:$iconFile", "/out:$outputFile")
foreach ($reference in $references) { $arguments += "/reference:$reference" }
$arguments += "/resource:$coreImageFile,JarvisNexusCore.png"
$arguments += $patchedSource
& $compilerPath @arguments
if ($LASTEXITCODE -ne 0) { throw "JARVIS Pet compilation failed with exit code $LASTEXITCODE." }
if (-not (Test-Path -LiteralPath $outputFile -PathType Leaf)) { throw 'Compiler reported success but output is missing.' }
Write-Host "Built x64 JARVIS Pet v2: $outputFile"
