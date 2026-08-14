<#!
.SYNOPSIS
  Типизированный исполнитель действий мыши, клавиатуры и окон для JARVIS NEXUS.

.DESCRIPTION
  Не принимает shell-команды, пути для запуска или произвольный PowerShell.
  Только явно разрешённые действия, проверенные параметры и JSON-результат.
  Сервер JARVIS вызывает этот файл лишь после прохождения safety gate.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('ScreenInfo', 'ActiveWindow', 'ListWindows', 'MoveMouse', 'Click', 'Scroll', 'TypeText', 'PressKey', 'Hotkey', 'FocusWindow', 'CloseWindow')]
    [string]$Action,

    [int]$X,
    [int]$Y,
    [int]$Amount,
    [ValidateSet('Left', 'Right', 'Middle')]
    [string]$Button = 'Left',
    [ValidateSet('Single', 'Double')]
    [string]$ClickKind = 'Single',
    [string]$Text,
    [ValidateSet('ENTER', 'ESC', 'TAB', 'SPACE', 'BACKSPACE', 'DELETE', 'UP', 'DOWN', 'LEFT', 'RIGHT', 'HOME', 'END', 'PGUP', 'PGDN', 'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12')]
    [string]$Key,
    [ValidateSet('CTRL+C', 'CTRL+V', 'CTRL+X', 'CTRL+Z', 'CTRL+Y', 'CTRL+A', 'CTRL+S', 'CTRL+F', 'CTRL+L', 'ALT+TAB', 'ALT+F4', 'WIN+D', 'WIN+E')]
    [string]$Keys,
    [string]$Title
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('NexusInput' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class NexusInput {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public InputUnion U; }
    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion { [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    const uint INPUT_KEYBOARD = 1;
    const uint KEYEVENTF_KEYUP = 0x0002;
    const uint KEYEVENTF_UNICODE = 0x0004;

    public static void SendUnicode(string value) {
        foreach (char c in value) {
            INPUT down = new INPUT { type = INPUT_KEYBOARD, U = new InputUnion { ki = new KEYBDINPUT { wVk = 0, wScan = c, dwFlags = KEYEVENTF_UNICODE } } };
            INPUT up = new INPUT { type = INPUT_KEYBOARD, U = new InputUnion { ki = new KEYBDINPUT { wVk = 0, wScan = c, dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP } } };
            INPUT[] inputs = new INPUT[] { down, up };
            if (SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))) != inputs.Length) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static string ForegroundTitle() {
        IntPtr handle = GetForegroundWindow();
        StringBuilder result = new StringBuilder(512);
        GetWindowText(handle, result, result.Capacity);
        return result.ToString();
    }
}
'@
}

function Write-Result([hashtable]$Data) {
    $Data.ok = $true
    $Data.action = $Action
    $Data | ConvertTo-Json -Compress -Depth 5
}

function Normalize-NexusWindowName([string]$Value) {
    $normalized = ([string]$Value).ToLowerInvariant()
    $normalized = [regex]::Replace($normalized, '[^\p{L}\p{Nd}]+', ' ')
    return [regex]::Replace($normalized, '\s+', ' ').Trim()
}

function Get-NexusWindowDistance([string]$Left, [string]$Right) {
    if ($Left -eq $Right) { return 0 }
    if (-not $Left) { return $Right.Length }
    if (-not $Right) { return $Left.Length }
    $previous = 0..$Right.Length
    for ($i = 1; $i -le $Left.Length; $i++) {
        $current = New-Object int[] ($Right.Length + 1)
        $current[0] = $i
        for ($j = 1; $j -le $Right.Length; $j++) {
            $cost = if ($Left[$i - 1] -eq $Right[$j - 1]) { 0 } else { 1 }
            $current[$j] = [Math]::Min([Math]::Min($current[$j - 1] + 1, $previous[$j] + 1), $previous[$j - 1] + $cost)
        }
        $previous = $current
    }
    return $previous[$Right.Length]
}

function Get-NexusWindowScore([string]$Query, [string]$Candidate) {
    if (-not $Candidate) { return 0 }
    if ($Query -eq $Candidate) { return 100 }
    if ($Candidate.StartsWith($Query) -or $Query.StartsWith($Candidate)) { return 94 }
    if ($Candidate.Contains($Query) -or $Query.Contains($Candidate)) { return 88 }
    $longest = [Math]::Max($Query.Length, $Candidate.Length)
    if ($longest -lt 4) { return 0 }
    $similarity = 1.0 - ((Get-NexusWindowDistance $Query $Candidate) / $longest)
    if ($similarity -ge 0.72) { return [int]($similarity * 84) }
    return 0
}

function Resolve-NexusWindow([string]$Query) {
    $normalized = Normalize-NexusWindowName $Query
    if (-not $normalized) { throw 'Window title is required.' }
    $ranked = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle } | ForEach-Object {
        $titleScore = Get-NexusWindowScore $normalized (Normalize-NexusWindowName $_.MainWindowTitle)
        $processScore = Get-NexusWindowScore $normalized (Normalize-NexusWindowName $_.ProcessName)
        [pscustomobject]@{ Process = $_; Score = [Math]::Max($titleScore, $processScore) }
    } | Where-Object { $_.Score -ge 60 } | Sort-Object Score -Descending)
    if ($ranked.Count -eq 0) { throw "Window not found: $Query" }
    if ($ranked.Count -gt 1 -and $ranked[0].Score -lt 88 -and ($ranked[0].Score - $ranked[1].Score) -lt 8) {
        throw "Several windows match '$Query': $($ranked[0].Process.MainWindowTitle); $($ranked[1].Process.MainWindowTitle)"
    }
    return $ranked[0].Process
}
function Test-ScreenPoint([int]$PointX, [int]$PointY) {
    $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($PointX -lt $screen.Left -or $PointX -ge ($screen.Left + $screen.Width) -or $PointY -lt $screen.Top -or $PointY -ge ($screen.Top + $screen.Height)) {
        throw "Coordinates $PointX,$PointY are outside the virtual desktop."
    }
}

function Send-ApprovedKey([string]$ApprovedKey) {
    $sendKey = @{
        'ENTER' = '{ENTER}'; 'ESC' = '{ESC}'; 'TAB' = '{TAB}'; 'SPACE' = ' ';
        'BACKSPACE' = '{BACKSPACE}'; 'DELETE' = '{DELETE}'; 'UP' = '{UP}'; 'DOWN' = '{DOWN}';
        'LEFT' = '{LEFT}'; 'RIGHT' = '{RIGHT}'; 'HOME' = '{HOME}'; 'END' = '{END}';
        'PGUP' = '{PGUP}'; 'PGDN' = '{PGDN}'; 'F1' = '{F1}'; 'F2' = '{F2}'; 'F3' = '{F3}';
        'F4' = '{F4}'; 'F5' = '{F5}'; 'F6' = '{F6}'; 'F7' = '{F7}'; 'F8' = '{F8}';
        'F9' = '{F9}'; 'F10' = '{F10}'; 'F11' = '{F11}'; 'F12' = '{F12}'
    }[$ApprovedKey]
    [System.Windows.Forms.SendKeys]::SendWait($sendKey)
}

function Send-ApprovedHotkey([string]$ApprovedKeys) {
    $sendKey = @{
        'CTRL+C' = '^c'; 'CTRL+V' = '^v'; 'CTRL+X' = '^x'; 'CTRL+Z' = '^z'; 'CTRL+Y' = '^y';
        'CTRL+A' = '^a'; 'CTRL+S' = '^s'; 'CTRL+F' = '^f'; 'CTRL+L' = '^l';
        'ALT+TAB' = '%{TAB}'; 'ALT+F4' = '%{F4}'; 'WIN+D' = '^{ESC}'; 'WIN+E' = '^{ESC}'
    }[$ApprovedKeys]
    if ($ApprovedKeys -in @('WIN+D', 'WIN+E')) {
        # Windows key itself is not exposed through SendKeys reliably. The server handles these by launching safe targets.
        throw "$ApprovedKeys is handled by the local server, not by SendKeys."
    }
    [System.Windows.Forms.SendKeys]::SendWait($sendKey)
}

try {
    switch ($Action) {
        'ScreenInfo' {
            $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
            Write-Result @{ left = $screen.Left; top = $screen.Top; width = $screen.Width; height = $screen.Height; cursorX = [System.Windows.Forms.Cursor]::Position.X; cursorY = [System.Windows.Forms.Cursor]::Position.Y; title = [NexusInput]::ForegroundTitle() }
        }
        'ActiveWindow' { Write-Result @{ title = [NexusInput]::ForegroundTitle() } }
        'ListWindows' {
            $windows = Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle } | Select-Object -First 40 @{ Name = 'process'; Expression = { $_.ProcessName } }, @{ Name = 'title'; Expression = { $_.MainWindowTitle } }
            Write-Result @{ windows = @($windows) }
        }
        'MoveMouse' {
            Test-ScreenPoint $X $Y
            [System.Windows.Forms.Cursor]::Position = [System.Drawing.Point]::new($X, $Y)
            Write-Result @{ x = $X; y = $Y }
        }
        'Click' {
            Test-ScreenPoint $X $Y
            [System.Windows.Forms.Cursor]::Position = [System.Drawing.Point]::new($X, $Y)
            $flags = @{ 'Left' = @(0x0002, 0x0004); 'Right' = @(0x0008, 0x0010); 'Middle' = @(0x0020, 0x0040) }[$Button]
            $repeat = if ($ClickKind -eq 'Double') { 2 } else { 1 }
            for ($i = 0; $i -lt $repeat; $i++) {
                [NexusInput]::mouse_event([uint32]$flags[0], 0, 0, 0, [UIntPtr]::Zero)
                [NexusInput]::mouse_event([uint32]$flags[1], 0, 0, 0, [UIntPtr]::Zero)
                if ($repeat -gt 1) { Start-Sleep -Milliseconds 90 }
            }
            Write-Result @{ x = $X; y = $Y; button = $Button; clickKind = $ClickKind }
        }
        'Scroll' {
            if ($Amount -eq 0 -or [Math]::Abs($Amount) -gt 25) { throw 'Scroll amount must be between -25 and 25, excluding 0.' }
            [NexusInput]::mouse_event(0x0800, 0, 0, [uint32]($Amount * 120), [UIntPtr]::Zero)
            Write-Result @{ amount = $Amount }
        }
        'TypeText' {
            if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 1000) { throw 'Text must contain 1 to 1000 characters.' }
            [NexusInput]::SendUnicode($Text)
            Write-Result @{ characters = $Text.Length }
        }
        'PressKey' {
            if (-not $Key) { throw 'Key is required.' }
            Send-ApprovedKey $Key
            Write-Result @{ key = $Key }
        }
        'Hotkey' {
            if (-not $Keys) { throw 'Keys are required.' }
            Send-ApprovedHotkey $Keys
            Write-Result @{ keys = $Keys }
        }
        'FocusWindow' {
            if ([string]::IsNullOrWhiteSpace($Title) -or $Title.Length -gt 120) { throw 'Window title is required and limited to 120 characters.' }
            $target = Resolve-NexusWindow $Title
            if (-not [NexusInput]::SetForegroundWindow($target.MainWindowHandle)) { throw "Windows did not allow focusing: $($target.MainWindowTitle)" }
            Write-Result @{ title = $target.MainWindowTitle; process = $target.ProcessName }
        }
        'CloseWindow' {
            if ([string]::IsNullOrWhiteSpace($Title) -or $Title.Length -gt 120) { throw 'Window title is required and limited to 120 characters.' }
            $target = Resolve-NexusWindow $Title
            $closedTitle = $target.MainWindowTitle
            $processName = $target.ProcessName
            $windowHandle = $target.MainWindowHandle
            if (-not $target.CloseMainWindow()) { throw "Windows did not accept a close request for: $closedTitle" }
            $deadline = [DateTime]::UtcNow.AddSeconds(6)
            do {
                Start-Sleep -Milliseconds 200
                $stillOpen = [NexusInput]::IsWindow($windowHandle)
            } while ($stillOpen -and [DateTime]::UtcNow -lt $deadline)
            if ($stillOpen) { throw "Window is still open: $closedTitle" }
            Write-Result @{ title = $closedTitle; process = $processName; closed = $true }
        }
    }
}
catch {
    [pscustomobject]@{ ok = $false; action = $Action; error = $_.Exception.Message } | ConvertTo-Json -Compress
    exit 1
}
