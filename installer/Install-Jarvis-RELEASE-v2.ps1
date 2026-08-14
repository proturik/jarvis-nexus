[CmdletBinding()]
param([switch]$Quiet)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InstallCore = Join-Path $PSScriptRoot 'Install-Jarvis-RELEASE.ps1'

if (-not (Test-Path -LiteralPath $InstallCore -PathType Leaf)) {
    throw "Installation core missing: $InstallCore"
}

function Run-PrivateInstall {
    & $InstallCore -Quiet
    if ($LASTEXITCODE -ne 0) { throw "Installation core stopped with code $LASTEXITCODE." }
}

function Show-NexusInstaller {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="JARVIS NEXUS ULTRA" Height="480" Width="760" WindowStyle="None" ResizeMode="NoResize" WindowStartupLocation="CenterScreen" Background="#050A14" Foreground="#DDFBFF">
  <Grid Margin="1">
    <Grid.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#071A2B" Offset="0"/><GradientStop Color="#05070F" Offset="0.56"/><GradientStop Color="#1D0B37" Offset="1"/></LinearGradientBrush></Grid.Background>
    <Border BorderBrush="#37F6FF" BorderThickness="1" CornerRadius="12" Padding="34">
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <Grid>
          <Ellipse x:Name="Halo" Width="282" Height="282" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-58,-64,0" Stroke="#24DFFF" StrokeThickness="2" Opacity="0.30"/>
          <Ellipse Width="206" Height="206" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-19,-26,0" Stroke="#A259FF" StrokeThickness="1" Opacity="0.65"/>
          <StackPanel Width="510" HorizontalAlignment="Left">
            <TextBlock Text="JARVIS // NEXUS ULTRA" FontFamily="Segoe UI Semibold" FontSize="14" Foreground="#65F7FF"/>
            <TextBlock Text="YOUR COMMAND DECK" FontFamily="Segoe UI Light" FontSize="35" Margin="0,18,0,9"/>
            <TextBlock Text="Private by design. Clean package. Local control." FontSize="15" Foreground="#AFC8D3"/>
            <Border Margin="0,30,0,15" Padding="17" Background="#101C2E" CornerRadius="8" BorderBrush="#294B68" BorderThickness="1">
              <StackPanel>
                <TextBlock Text="SECURITY CORE // CURRENT USER ONLY" FontWeight="Bold" Foreground="#FFB65C"/>
                <TextBlock x:Name="Detail" Margin="0,8,0,0" Text="No chats, profile, files, API keys or screen data are contained in this installer." TextWrapping="Wrap" Foreground="#D8EDF5"/>
              </StackPanel>
            </Border>
            <TextBlock x:Name="Status" Margin="2,18,0,0" Text="READY // NO ADMIN RIGHTS // LOCAL STORAGE" Foreground="#65F7FF" FontWeight="SemiBold"/>
          </StackPanel>
        </Grid>
        <Grid Grid.Row="1" Margin="0,18,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="145"/><ColumnDefinition Width="100"/></Grid.ColumnDefinitions>
          <TextBlock VerticalAlignment="Center" Text="JARVIS NEXUS ULTRA" Foreground="#7894A7"/>
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
    $status = $window.FindName('Status')
    $detail = $window.FindName('Detail')
    $installButton = $window.FindName('InstallButton')
    $closeButton = $window.FindName('CloseButton')
    $halo = $window.FindName('Halo')
    $pulse = New-Object System.Windows.Media.Animation.DoubleAnimation
    $pulse.From = 0.16; $pulse.To = 0.67
    $pulse.Duration = [System.Windows.Duration]::new([TimeSpan]::FromSeconds(1.65))
    $pulse.AutoReverse = $true
    $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $halo.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $pulse)
    $script:finished = $false
    $installButton.Add_Click({
        if ($script:finished) { $window.Close(); return }
        $installButton.IsEnabled = $false
        $closeButton.IsEnabled = $false
        $status.Text = 'VERIFYING PACKAGE INTEGRITY...'
        $detail.Text = 'Installing a separate local JARVIS profile for this Windows user.'
        try {
            Run-PrivateInstall
            $script:finished = $true
            $status.Text = 'NEXUS ONLINE // LOCAL MEMORY READY'
            $detail.Text = 'Installation complete. Your future chats and settings stay only in this Windows account.'
            $installButton.Content = 'DONE'
            $installButton.IsEnabled = $true
            $closeButton.IsEnabled = $true
        }
        catch {
            $status.Text = 'INSTALLATION STOPPED SAFELY'
            $detail.Text = $_.Exception.Message
            $installButton.IsEnabled = $true
            $closeButton.IsEnabled = $true
        }
    })
    $closeButton.Add_Click({ $window.Close() })
    $window.Add_MouseLeftButtonDown({ $window.DragMove() })
    [void]$window.ShowDialog()
}

if ($Quiet) { Run-PrivateInstall }
else { Show-NexusInstaller }
