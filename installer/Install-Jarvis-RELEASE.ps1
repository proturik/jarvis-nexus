[CmdletBinding()]
param([switch]$Quiet)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Manifest {
    $manifestPath = Join-Path $PSScriptRoot 'installer-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Installer manifest is missing.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($manifest.payloadFile) -or [string]::IsNullOrWhiteSpace($manifest.payloadSha256)) { throw 'Installer manifest is invalid.' }
    return $manifest
}

function Test-Payload([object]$Manifest) {
    $payloadPath = Join-Path $PSScriptRoot ([string]$Manifest.payloadFile)
    if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) { throw 'Installer payload is missing.' }
    $actual = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actual -ne ([string]$Manifest.payloadSha256).ToUpperInvariant()) { throw 'Payload integrity check failed. Stop installation and obtain a fresh installer.' }
    return $payloadPath
}

function New-Shortcut([string]$Path, [string]$TargetPath, [string]$Description) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $TargetPath
    $shortcut.WorkingDirectory = Split-Path -Parent $TargetPath
    $shortcut.Description = $Description
    $shortcut.Save()
}

function Install-Release([bool]$DesktopShortcut, [bool]$StartupShortcut) {
    $manifest = Get-Manifest
    $payloadPath = Test-Payload $manifest
    $installRoot = Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA'
    $extractRoot = Join-Path $env:TEMP ('JARVIS-NEXUS-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $extractRoot -ErrorAction Stop | Out-Null
    try {
        Expand-Archive -LiteralPath $payloadPath -DestinationPath $extractRoot -Force
        foreach ($name in @('app', 'runtime', 'launcher')) {
            $source = Join-Path $extractRoot $name
            if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Payload folder missing: $name" }
            $destination = Join-Path $installRoot $name
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $source '*') -Destination $destination -Recurse -Force
        }
        # Never copy user data: it is created locally and remains untouched on updates.
        New-Item -ItemType Directory -Path (Join-Path $installRoot 'app\data') -Force | Out-Null
        $launcher = Join-Path $installRoot 'launcher\Start-Jarvis-RELEASE.cmd'
        if ($DesktopShortcut) { New-Shortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'JARVIS NEXUS ULTRA.lnk') $launcher 'Launch JARVIS NEXUS ULTRA' }
        $startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'JARVIS NEXUS ULTRA.lnk'
        if ($StartupShortcut) { New-Shortcut $startupLink $launcher 'Launch JARVIS NEXUS ULTRA at sign-in' }
        elseif (Test-Path -LiteralPath $startupLink -PathType Leaf) { Remove-Item -LiteralPath $startupLink -Force }
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $installRoot 'release.json') -Encoding utf8
        return $installRoot
    }
    finally {
        if (Test-Path -LiteralPath $extractRoot -PathType Container) { Remove-Item -LiteralPath $extractRoot -Recurse -Force }
    }
}

function Start-InstalledJarvis([string]$InstallRoot) {
    Start-Process -FilePath (Join-Path $InstallRoot 'launcher\Start-Jarvis-RELEASE.cmd')
}

function Show-InstallerWindow {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="JARVIS NEXUS ULTRA" Height="495" Width="760" WindowStyle="None" ResizeMode="NoResize" WindowStartupLocation="CenterScreen" Background="#050A14" Foreground="#DDFBFF">
  <Grid Margin="1">
    <Grid.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#071A2B" Offset="0"/><GradientStop Color="#05070F" Offset="0.55"/><GradientStop Color="#160A2C" Offset="1"/></LinearGradientBrush></Grid.Background>
    <Border BorderBrush="#37F6FF" BorderThickness="1" CornerRadius="12" Padding="34">
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <Grid>
          <Ellipse x:Name="CyanHalo" Width="265" Height="265" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-45,-55,0" Stroke="#24DFFF" StrokeThickness="2" Opacity="0.30"/>
          <Ellipse Width="188" Height="188" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-6,-18,0" Stroke="#9E58FF" StrokeThickness="1" Opacity="0.55"/>
          <StackPanel Width="500" HorizontalAlignment="Left">
            <TextBlock Text="JARVIS // NEXUS ULTRA" FontFamily="Segoe UI Semibold" FontSize="13" Foreground="#65F7FF" CharacterSpacing="90"/>
            <TextBlock Text="YOUR COMMAND DECK" FontFamily="Segoe UI Light" FontSize="35" Margin="0,18,0,9"/>
            <TextBlock Text="A private desktop companion. Your chats, memories and keys stay on this PC." FontSize="15" Foreground="#AFC8D3" TextWrapping="Wrap"/>
            <Border Margin="0,29,0,16" Padding="16" Background="#101C2E" CornerRadius="8" BorderBrush="#294B68" BorderThickness="1">
              <StackPanel>
                <TextBlock Text="SECURITY CORE" FontWeight="Bold" Foreground="#FFB65C"/>
                <TextBlock x:Name="Detail" Margin="0,8,0,0" Text="Clean package: no chat history, profile, files, API keys or screen data are included." TextWrapping="Wrap" Foreground="#D8EDF5"/>
              </StackPanel>
            </Border>
            <CheckBox x:Name="DesktopShortcut" IsChecked="True" Content="Create a desktop launcher" Margin="2,5" Foreground="#DDFBFF"/>
            <CheckBox x:Name="StartupShortcut" IsChecked="False" Content="Launch JARVIS when I sign in" Margin="2,5" Foreground="#DDFBFF"/>
            <TextBlock x:Name="Status" Margin="2,18,0,0" Text="READY // LOCAL INSTALL // NO ADMIN RIGHTS" Foreground="#65F7FF" FontWeight="SemiBold"/>
          </StackPanel>
        </Grid>
        <Grid Grid.Row="1" Margin="0,18,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="145"/><ColumnDefinition Width="100"/></Grid.ColumnDefinitions>
          <TextBlock x:Name="Version" VerticalAlignment="Center" Foreground="#7894A7"/>
          <Button x:Name="InstallButton" Grid.Column="1" Height="43" Margin="0,0,10,0" Content="INSTALL" FontWeight="Bold" Background="#16BFD1" Foreground="#021016" BorderThickness="0"/>
          <Button x:Name="CloseButton" Grid.Column="2" Height="43" Content="CLOSE" Background="#172A3C" Foreground="#DDFBFF" BorderBrush="#41657B"/>
        </Grid>
      </Grid>
    </Border>
  </Grid>
</Window>
'@
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $status = $window.FindName('Status'); $detail = $window.FindName('Detail'); $version = $window.FindName('Version')
    $desktop = $window.FindName('DesktopShortcut'); $startup = $window.FindName('StartupShortcut')
    $installButton = $window.FindName('InstallButton'); $closeButton = $window.FindName('CloseButton'); $halo = $window.FindName('CyanHalo')
    $manifest = Get-Manifest
    $version.Text = "VERSION $($manifest.version) // CURRENT USER"
    $pulse = New-Object System.Windows.Media.Animation.DoubleAnimation
    $pulse.From = 0.15; $pulse.To = 0.62; $pulse.Duration = [System.Windows.Duration]::new([TimeSpan]::FromSeconds(1.7)); $pulse.AutoReverse = $true; $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $halo.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $pulse)
    $script:releaseInstalled = $false; $script:releaseRoot = $null
    $installButton.Add_Click({
        if ($script:releaseInstalled) { Start-InstalledJarvis $script:releaseRoot; $window.Close(); return }
        $installButton.IsEnabled = $false; $closeButton.IsEnabled = $false
        $status.Text = 'VERIFYING PACKAGE INTEGRITY...'; $detail.Text = 'Building your local, private command deck.'
        try {
            $script:releaseRoot = Install-Release ([bool]$desktop.IsChecked) ([bool]$startup.IsChecked)
            $script:releaseInstalled = $true
            $status.Text = 'NEXUS ONLINE // PRIVATE STORAGE READY'
            $detail.Text = "Installed for this Windows user only: $($script:releaseRoot)"
            $installButton.Content = 'LAUNCH'; $installButton.IsEnabled = $true; $closeButton.IsEnabled = $true
        }
        catch {
            $status.Text = 'INSTALLATION STOPPED SAFELY'
            $detail.Text = $_.Exception.Message
            $installButton.IsEnabled = $true; $closeButton.IsEnabled = $true
        }
    })
    $closeButton.Add_Click({ $window.Close() })
    $window.Add_MouseLeftButtonDown({ $window.DragMove() })
    [void]$window.ShowDialog()
}

if ($Quiet) {
    $root = Install-Release $true $false
    Start-InstalledJarvis $root
}
else { Show-InstallerWindow }
