[CmdletBinding()]
param(
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProductName = 'JARVIS NEXUS ULTRA'
$InstallerRoot = $PSScriptRoot
$PayloadZip = Join-Path $InstallerRoot 'payload.zip'
$ManifestPath = Join-Path $InstallerRoot 'installer-manifest.json'

function Get-InstallerManifest {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "$ProductName installer manifest is missing."
    }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if (-not $manifest.payloadSha256 -or -not $manifest.version) {
        throw "$ProductName installer manifest is invalid."
    }
    return $manifest
}

function Test-PayloadIntegrity {
    param($Manifest)

    if (-not (Test-Path -LiteralPath $PayloadZip -PathType Leaf)) {
        throw "$ProductName installation payload is missing."
    }

    $actual = (Get-FileHash -LiteralPath $PayloadZip -Algorithm SHA256).Hash.ToUpperInvariant()
    $expected = ([string]$Manifest.payloadSha256).Trim().ToUpperInvariant()
    if ($actual -ne $expected) {
        throw "$ProductName payload integrity check failed. Expected $expected, got $actual."
    }
}

function Copy-PayloadDirectory {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "$ProductName package is missing: $Source"
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        New-Item -ItemType Directory -Path $Destination -ErrorAction Stop | Out-Null
    }

    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function New-JarvisShortcut {
    param(
        [string]$Path,
        [string]$Launcher,
        [string]$WorkingDirectory
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return $false
    }

    $quote = [char]34
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + $quote + $Launcher + $quote
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.IconLocation = "$env:SystemRoot\System32\imageres.dll,102"
    $shortcut.Description = 'Launch JARVIS NEXUS ULTRA'
    $shortcut.Save()
    return $true
}

function Start-Jarvis {
    param([string]$InstallRoot)

    $launcher = Join-Path $InstallRoot 'Start-Jarvis.ps1'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw "$ProductName launcher is missing: $launcher"
    }

    $quote = [char]34
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + $quote + $launcher + $quote
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments | Out-Null
}

function Invoke-JarvisInstallation {
    param(
        [bool]$CreateDesktopShortcut,
        [bool]$CreateStartupShortcut,
        [scriptblock]$OnStatus
    )

    $manifest = Get-InstallerManifest
    & $OnStatus 'Проверяю целостность локального пакета…'
    Test-PayloadIntegrity $manifest

    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $installRoot = Join-Path $localAppData $ProductName
    $appRoot = Join-Path $installRoot 'app'
    $runtimeRoot = Join-Path $installRoot 'runtime'
    $dataRoot = Join-Path $appRoot 'data'
    $extractionRoot = Join-Path $InstallerRoot ('JNU-payload-' + [guid]::NewGuid().ToString('N'))

    & $OnStatus 'Готовлю безопасную установку для текущего пользователя…'
    New-Item -ItemType Directory -Path $installRoot, $appRoot, $runtimeRoot -ErrorAction Stop | Out-Null
    Expand-Archive -LiteralPath $PayloadZip -DestinationPath $extractionRoot -ErrorAction Stop

    $packageApp = Join-Path $extractionRoot 'app'
    $packageRuntime = Join-Path $extractionRoot 'runtime'
    $packageLauncher = Join-Path $extractionRoot 'launcher'
    if (Test-Path -LiteralPath (Join-Path $packageApp 'data')) {
        throw "$ProductName package safety check failed: it must not contain user data."
    }
    if (Test-Path -LiteralPath (Join-Path $packageApp '.env') -PathType Leaf) {
        throw "$ProductName package safety check failed: it must not contain a user .env file."
    }

    & $OnStatus 'Обновляю ядро и эффекты, не трогая память и настройки…'
    Copy-PayloadDirectory -Source $packageApp -Destination $appRoot
    Copy-PayloadDirectory -Source $packageRuntime -Destination $runtimeRoot
    Copy-PayloadDirectory -Source $packageLauncher -Destination $installRoot
    if (-not (Test-Path -LiteralPath $dataRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $dataRoot -ErrorAction Stop | Out-Null
    }

    Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $installRoot 'install-manifest.json') -Force

    $result = [ordered]@{
        InstallRoot = $installRoot
        Version = [string]$manifest.version
        DesktopShortcutCreated = $false
        StartupShortcutCreated = $false
    }

    $launcher = Join-Path $installRoot 'Start-Jarvis.ps1'
    if ($CreateDesktopShortcut) {
        $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
        $desktopLink = Join-Path $desktop "$ProductName.lnk"
        $result.DesktopShortcutCreated = New-JarvisShortcut -Path $desktopLink -Launcher $launcher -WorkingDirectory $installRoot
    }
    if ($CreateStartupShortcut) {
        $startup = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
        $startupLink = Join-Path $startup "$ProductName.lnk"
        $result.StartupShortcutCreated = New-JarvisShortcut -Path $startupLink -Launcher $launcher -WorkingDirectory $installRoot
    }

    & $OnStatus 'Синхронизация завершена. Память и .env сохранены.'
    return [pscustomobject]$result
}

function Show-InstallerWindow {
    $manifest = Get-InstallerManifest
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="JARVIS NEXUS ULTRA"
        Width="760" Height="500"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Background="#050914"
        FontFamily="Segoe UI"
        Foreground="#F4FBFF">
  <Grid ClipToBounds="True">
    <Grid.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
        <GradientStop Color="#040710" Offset="0"/>
        <GradientStop Color="#091B32" Offset="0.48"/>
        <GradientStop Color="#100B2C" Offset="1"/>
      </LinearGradientBrush>
    </Grid.Background>
    <Ellipse x:Name="CyanHalo" Width="440" Height="440" Fill="#163EF0FF" Opacity="0.22" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="-185,-205,0,0">
      <Ellipse.Effect><BlurEffect Radius="80"/></Ellipse.Effect>
    </Ellipse>
    <Ellipse x:Name="VioletHalo" Width="360" Height="360" Fill="#194E4BFF" Opacity="0.18" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,-125,-155">
      <Ellipse.Effect><BlurEffect Radius="78"/></Ellipse.Effect>
    </Ellipse>
    <Border Margin="26" Padding="34" CornerRadius="28" BorderThickness="1" BorderBrush="#66B3F6FF">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
          <GradientStop Color="#E30A172B" Offset="0"/>
          <GradientStop Color="#CC0A1022" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <Border.Effect><DropShadowEffect Color="#29A7F7" BlurRadius="34" ShadowDepth="0" Opacity="0.42"/></Border.Effect>
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="190"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Row="0" Grid.Column="0">
          <TextBlock Text="NEXUS // INSTALLER" FontSize="12" FontWeight="SemiBold" Foreground="#8EEBFF"/>
          <TextBlock Text="JARVIS" FontSize="50" FontWeight="Bold" Margin="0,9,0,0"/>
          <TextBlock Text="ULTRA EDITION" FontSize="18" FontWeight="SemiBold" Foreground="#CB9CFF"/>
        </StackPanel>
        <Border Grid.Row="0" Grid.Column="1" Width="126" Height="126" HorizontalAlignment="Right" CornerRadius="63" BorderThickness="2" BorderBrush="#71DDFE" Background="#10081727">
          <Border.Effect><DropShadowEffect Color="#4EEBFF" BlurRadius="28" ShadowDepth="0" Opacity="0.8"/></Border.Effect>
          <Grid>
            <Ellipse Width="78" Height="78" Stroke="#C8F8FF" StrokeThickness="2"/>
            <Ellipse Width="48" Height="48" Stroke="#826CFF" StrokeThickness="2"/>
            <Ellipse Width="15" Height="15" Fill="#9DF5FF">
              <Ellipse.Effect><DropShadowEffect Color="#74F0FF" BlurRadius="16" ShadowDepth="0" Opacity="1"/></Ellipse.Effect>
            </Ellipse>
          </Grid>
        </Border>
        <StackPanel Grid.Row="1" Grid.ColumnSpan="2" VerticalAlignment="Center" Margin="0,25,0,16">
          <TextBlock Text="Локальная установка. Никаких скачиваний, рекламы или доступа к облаку без твоего выбора." FontSize="16" Foreground="#C9D8E9" TextWrapping="Wrap"/>
          <Border Margin="0,23,0,18" Padding="18,14" CornerRadius="15" Background="#600E1B30" BorderBrush="#2F88C5" BorderThickness="1">
            <StackPanel>
              <TextBlock x:Name="Status" Text="Готов к установке." FontSize="15" Foreground="#EAF9FF"/>
              <TextBlock x:Name="Detail" Text="Память, история общения и .env никогда не входят в обновления." Margin="0,7,0,0" FontSize="12" Foreground="#86A2BF"/>
            </StackPanel>
          </Border>
          <ProgressBar x:Name="Progress" Height="5" Minimum="0" Maximum="100" Value="9" Background="#1E3E5F" Foreground="#5DE7FF" BorderThickness="0"/>
          <StackPanel Margin="0,20,0,0">
            <CheckBox x:Name="DesktopShortcut" IsChecked="True" Content="Добавить ярлык на рабочий стол" Foreground="#D7E8F8" FontSize="13" Margin="0,0,0,9"/>
            <CheckBox x:Name="StartupShortcut" IsChecked="False" Content="Запускать JARVIS вместе с Windows" Foreground="#D7E8F8" FontSize="13"/>
          </StackPanel>
        </StackPanel>
        <Grid Grid.Row="2" Grid.ColumnSpan="2">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="Version" Grid.Column="0" VerticalAlignment="Center" Foreground="#8299B0" FontSize="12"/>
          <Button x:Name="CloseButton" Grid.Column="1" Content="ПОЗЖЕ" Padding="16,10" Margin="0,0,10,0" Background="Transparent" Foreground="#B8CADB" BorderBrush="#41617E"/>
          <Button x:Name="InstallButton" Grid.Column="2" Content="АКТИВИРОВАТЬ" Padding="23,10" FontWeight="Bold" Background="#38DDFE" Foreground="#06111E" BorderBrush="#B4F7FF">
            <Button.Effect><DropShadowEffect Color="#3CE5FF" BlurRadius="20" ShadowDepth="0" Opacity="0.7"/></Button.Effect>
          </Button>
        </Grid>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $cyanHalo = $window.FindName('CyanHalo')
    $status = $window.FindName('Status')
    $detail = $window.FindName('Detail')
    $progress = $window.FindName('Progress')
    $desktopShortcut = $window.FindName('DesktopShortcut')
    $startupShortcut = $window.FindName('StartupShortcut')
    $installButton = $window.FindName('InstallButton')
    $closeButton = $window.FindName('CloseButton')
    $versionLabel = $window.FindName('Version')
    $versionLabel.Text = "v$($manifest.version)  •  current-user install"

    $pulse = New-Object System.Windows.Media.Animation.DoubleAnimation
    $pulse.From = 0.10
    $pulse.To = 0.35
    $pulse.Duration = [System.Windows.Duration]::new([TimeSpan]::FromSeconds(1.8))
    $pulse.AutoReverse = $true
    $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $cyanHalo.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $pulse)

    $script:jarvisInstalled = $false
    $script:jarvisInstallRoot = $null
    $installButton.Add_Click({
        if ($script:jarvisInstalled) {
            Start-Jarvis -InstallRoot $script:jarvisInstallRoot
            $window.Close()
            return
        }

        $installButton.IsEnabled = $false
        $closeButton.IsEnabled = $false
        $progress.IsIndeterminate = $true
        $status.Text = 'Синхронизирую NEXUS…'
        $detail.Text = 'Ни один пользовательский файл не будет удалён.'

        $operation = [Action]{
            try {
                $result = Invoke-JarvisInstallation -CreateDesktopShortcut ([bool]$desktopShortcut.IsChecked) -CreateStartupShortcut ([bool]$startupShortcut.IsChecked) -OnStatus {
                    param($message)
                    $status.Text = $message
                }
                $script:jarvisInstalled = $true
                $script:jarvisInstallRoot = $result.InstallRoot
                $progress.IsIndeterminate = $false
                $progress.Value = 100
                $status.Text = 'JARVIS NEXUS ULTRA активирован.'
                $detail.Text = "Память переживёт перезапуск ПК. Установлено в $($result.InstallRoot)"
                $installButton.Content = 'ЗАПУСТИТЬ JARVIS'
                $installButton.IsEnabled = $true
                $closeButton.IsEnabled = $true
                $closeButton.Content = 'ГОТОВО'
            }
            catch {
                $progress.IsIndeterminate = $false
                $progress.Value = 0
                $status.Text = 'Установка остановлена безопасно.'
                $detail.Text = $_.Exception.Message
                $installButton.IsEnabled = $true
                $closeButton.IsEnabled = $true
            }
        }
        $window.Dispatcher.BeginInvoke($operation, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
    })
    $closeButton.Add_Click({ $window.Close() })
    [void]$window.ShowDialog()
}

if ($Quiet) {
    $result = Invoke-JarvisInstallation -CreateDesktopShortcut $true -CreateStartupShortcut $false -OnStatus {
        param($message)
        Write-Host "$ProductName: $message"
    }
    Write-Host "$ProductName installed to $($result.InstallRoot)"
    exit 0
}

try {
    Show-InstallerWindow
}
catch {
    Write-Error "$ProductName installer failed: $($_.Exception.Message)"
    exit 1
}
