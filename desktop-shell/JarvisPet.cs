using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Speech.Synthesis;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace JarvisNexus.DesktopShell
{
    /// <summary>
    /// Small native WPF desktop companion for the local JARVIS NEXUS ULTRA service.
    /// It deliberately has no microphone, speech recognition, or wake-word code:
    /// a Russian Windows recognizer is not reliably available on target systems.
    /// </summary>
    internal sealed class JarvisPetWindow : Window
    {
        private const string LocalService = "http://127.0.0.1:3791/";
        private const string LocalTtsService = "http://127.0.0.1:3793/";
        private const double CompactWidth = 342;
        private const double ExpandedWidth = 676;
        private const double ShellHeight = 408;

        private static readonly Brush SurfaceBrush = CreateBrush(5, 13, 24);
        private static readonly Brush SurfaceAltBrush = CreateBrush(7, 22, 34);
        private static readonly Brush CyanBrush = CreateBrush(0, 255, 255);
        private static readonly Brush CyanSoftBrush = CreateBrush(98, 232, 255);
        private static readonly Brush PurpleBrush = CreateBrush(158, 102, 255);
        private static readonly Brush OrangeBrush = CreateBrush(255, 110, 0);
        private static readonly Brush GreenBrush = CreateBrush(74, 255, 164);
        private static readonly Brush MutedBrush = CreateBrush(135, 167, 185);
        private static readonly JavaScriptSerializer Serializer = new JavaScriptSerializer();
        private static readonly HttpClient Http = CreateHttpClient();
        private static readonly HttpClient NeuralTtsHttp = CreateTtsHttpClient();

        private readonly TextBlock _statusText;
        private readonly TextBlock _voiceText;
        private readonly TextBlock _replyText;
        private readonly TextBlock _actionTitleText;
        private readonly TextBlock _actionDetailText;
        private readonly TextBox _commandBox;
        private readonly Button _sendButton;
        private readonly Button _confirmButton;
        private readonly Button _pinButton;
        private readonly Button _microphoneButton;
        private readonly Button _voiceToggleButton;
        private readonly Button _visionToggleButton;
        private readonly ContextMenu _microphoneMenu;
        private readonly Border _commandPanel;
        private readonly Border _actionCard;

        private SpeechSynthesizer _speaker;
        private PendingAction _pendingAction;
        private bool _hasRussianVoice;
        private bool _panelOpen;
        private bool _busy;
        private bool _voiceSenseEnabled;
        private bool _visionSenseEnabled;
        private bool _senseSettingsWritable;
        private int? _microphoneDevice;
        private string _microphoneDeviceCaption;
        private bool _microphoneListLoading;
        private bool _microphoneListError;
        private readonly string _senseSettingsPath;
        private readonly string _senseExecutablePath;
        private DispatcherTimer _visualTimer;
        private Ellipse _microphoneActivityRing;
        private Ellipse _replyActivityRing;
        private Ellipse _thinkingRing;
        private ScaleTransform _microphoneActivityScale;
        private ScaleTransform _replyActivityScale;
        private ScaleTransform _hubScale;
        private bool _visualPollBusy;
        private string _coreVisualState = "idle";
        private string _lastSenseCommand = string.Empty;
        private string _lastSenseReply = string.Empty;

        public JarvisPetWindow()
        {
            Title = "JARVIS NEXUS Pet";
            Width = CompactWidth;
            Height = ShellHeight;
            MinWidth = CompactWidth;
            MinHeight = ShellHeight;
            MaxHeight = ShellHeight;
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            Topmost = true;
            ShowInTaskbar = true;
            FontFamily = new FontFamily("Bahnschrift");

            _senseSettingsPath = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "JARVIS NEXUS ULTRA",
                "app",
                "data",
                "sense-settings.json");
            _senseExecutablePath = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "JARVIS NEXUS ULTRA",
                "desktop-shell",
                "sense",
                "JarvisSense.exe");
            LoadSenseSettings();
            ConfigureSpeech();

            _statusText = CreateText("CORE // ГОТОВ", 11, CyanSoftBrush, FontWeights.SemiBold);
            _voiceText = CreateText(
                File.Exists(_senseExecutablePath) ? "NEURAL // ГОТОВ" : (_hasRussianVoice ? "SAPI RU // ГОТОВ" : "ГОЛОС // НЕДОСТУПЕН"),
                9,
                File.Exists(_senseExecutablePath) || _hasRussianVoice ? MutedBrush : OrangeBrush,
                FontWeights.Normal);
            _replyText = CreateText(
                "Нажмите на ядро, чтобы открыть командную панель.",
                13,
                CreateBrush(221, 244, 255),
                FontWeights.Normal);
            _replyText.TextWrapping = TextWrapping.Wrap;
            _replyText.LineHeight = 19;

            _actionTitleText = CreateText(string.Empty, 11, OrangeBrush, FontWeights.SemiBold);
            _actionTitleText.TextWrapping = TextWrapping.Wrap;
            _actionDetailText = CreateText(string.Empty, 10, MutedBrush, FontWeights.Normal);
            _actionDetailText.TextWrapping = TextWrapping.Wrap;

            _commandBox = CreateCommandBox();
            _sendButton = CreateButton("ОТПРАВИТЬ", CyanBrush, CreateBrush(0, 51, 65), CreateBrush(0, 160, 180), 10);
            _sendButton.Click += SendChatAsync;

            _confirmButton = CreateButton("ПОДТВЕРДИТЬ", OrangeBrush, CreateBrush(61, 27, 8), CreateBrush(255, 110, 0), 10);
            _confirmButton.Click += ConfirmActionAsync;

            _pinButton = CreateButton("PIN ON", CyanBrush, Brushes.Transparent, CreateBrush(0, 132, 154), 9);
            _pinButton.Click += ToggleTopmost;

            _microphoneButton = CreateButton("MIC // AUTO", CyanSoftBrush, Brushes.Transparent, CreateBrush(0, 132, 154), 7.5);
            _microphoneButton.MinHeight = 24;
            _microphoneButton.ToolTip = "Выбрать локальный микрофон для фразы «Джарвис»";
            _microphoneMenu = CreateMicrophoneMenu();
            _microphoneButton.Click += OpenMicrophoneMenuAsync;

            _voiceToggleButton = CreateButton("VOICE // OFF", MutedBrush, Brushes.Transparent, CreateBrush(0, 92, 118), 8);
            _voiceToggleButton.MinHeight = 24;
            _voiceToggleButton.ToolTip = "Включить или выключить локальную фразу «Джарвис»";
            _voiceToggleButton.Click += ToggleVoiceSense;

            _visionToggleButton = CreateButton("VISION // OFF", MutedBrush, Brushes.Transparent, CreateBrush(0, 92, 118), 8);
            _visionToggleButton.MinHeight = 24;
            _visionToggleButton.ToolTip = "Включить или выключить локальный анализ экрана";
            _visionToggleButton.Click += ToggleVisionSense;

            _actionCard = BuildActionCard();
            _commandPanel = BuildCommandPanel();

            Content = BuildShell();
            _visualTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(120) };
            _visualTimer.Tick += PollSenseVisualState;
            _visualTimer.Start();
            Loaded += PositionNearWorkArea;
            Closed += DisposeSpeech;
            _commandBox.TextChanged += CommandTextChanged;
            _commandBox.KeyDown += CommandBoxKeyDown;
            UpdateControls();
            UpdateSenseButtons();
            UpdateMicrophoneButton();
            if (!_senseSettingsWritable)
            {
                SetStatus("SENSE // CONFIG ERROR");
            }
        }

        private UIElement BuildShell()
        {
            var root = new Grid
            {
                Margin = new Thickness(7),
                ClipToBounds = false
            };
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(328) });
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(326) });

            var shell = new Border
            {
                Background = SurfaceBrush,
                BorderBrush = CreateBrush(0, 142, 166),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(22),
                Effect = new DropShadowEffect
                {
                    Color = Color.FromRgb(0, 229, 255),
                    BlurRadius = 24,
                    ShadowDepth = 0,
                    Opacity = 0.22
                }
            };

            var shellGrid = new Grid();
            shellGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(328) });
            shellGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(326) });

            var corePane = BuildCorePane();
            Grid.SetColumn(corePane, 0);
            shellGrid.Children.Add(corePane);

            Grid.SetColumn(_commandPanel, 1);
            shellGrid.Children.Add(_commandPanel);

            shell.Child = shellGrid;
            root.Children.Add(shell);
            return root;
        }

        private UIElement BuildCorePane()
        {
            var pane = new Grid
            {
                Margin = new Thickness(11, 8, 11, 10)
            };
            pane.RowDefinitions.Add(new RowDefinition { Height = new GridLength(38) });
            pane.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            pane.RowDefinitions.Add(new RowDefinition { Height = new GridLength(58) });

            var titleBar = BuildTitleBar();
            Grid.SetRow(titleBar, 0);
            pane.Children.Add(titleBar);

            var core = BuildHolographicCore();
            Grid.SetRow(core, 1);
            pane.Children.Add(core);

            var footer = new StackPanel
            {
                VerticalAlignment = VerticalAlignment.Bottom,
                HorizontalAlignment = HorizontalAlignment.Center
            };
            footer.Children.Add(_statusText);
            footer.Children.Add(new Border { Height = 3, Background = Brushes.Transparent });
            footer.Children.Add(_voiceText);
            footer.Children.Add(new Border { Height = 4, Background = Brushes.Transparent });
            footer.Children.Add(BuildSenseToggleRow());

            Grid.SetRow(footer, 2);
            pane.Children.Add(footer);
            return pane;
        }

        private UIElement BuildSenseToggleRow()
        {
            var row = new Grid
            {
                Width = 280,
                HorizontalAlignment = HorizontalAlignment.Center
            };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            _voiceToggleButton.Margin = new Thickness(0, 0, 3, 0);
            _visionToggleButton.Margin = new Thickness(3, 0, 0, 0);
            row.Children.Add(_voiceToggleButton);
            Grid.SetColumn(_visionToggleButton, 1);
            row.Children.Add(_visionToggleButton);
            return row;
        }

        private UIElement BuildTitleBar()
        {
            var titleBar = new Grid
            {
                Cursor = Cursors.SizeAll,
                Background = Brushes.Transparent
            };
            titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(72) });
            titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(49) });
            titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(29) });
            titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(29) });
            titleBar.PreviewMouseLeftButtonDown += DragWindow;

            var brand = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                VerticalAlignment = VerticalAlignment.Center,
                IsHitTestVisible = false
            };
            var liveDot = new Ellipse
            {
                Width = 7,
                Height = 7,
                Fill = GreenBrush,
                Margin = new Thickness(1, 0, 7, 0),
                Effect = new DropShadowEffect { Color = Color.FromRgb(74, 255, 164), BlurRadius = 8, ShadowDepth = 0, Opacity = 0.9 }
            };
            brand.Children.Add(liveDot);
            brand.Children.Add(CreateText("JARVIS // NEXUS", 11, CyanBrush, FontWeights.SemiBold));
            titleBar.Children.Add(brand);

            Grid.SetColumn(_microphoneButton, 1);
            titleBar.Children.Add(_microphoneButton);

            Grid.SetColumn(_pinButton, 2);
            titleBar.Children.Add(_pinButton);

            var minimize = CreateButton("—", MutedBrush, Brushes.Transparent, Brushes.Transparent, 13);
            minimize.ToolTip = "Свернуть";
            minimize.Click += delegate { WindowState = WindowState.Minimized; };
            Grid.SetColumn(minimize, 3);
            titleBar.Children.Add(minimize);

            var close = CreateButton("×", OrangeBrush, Brushes.Transparent, Brushes.Transparent, 18);
            close.ToolTip = "Закрыть";
            close.Click += delegate { Close(); };
            Grid.SetColumn(close, 4);
            titleBar.Children.Add(close);

            return titleBar;
        }

        private UIElement BuildHolographicCore()
        {
            var host = new Grid
            {
                Width = 280,
                Height = 280,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Cursor = Cursors.Hand,
                ToolTip = "Открыть или скрыть командную панель"
            };
            host.MouseLeftButtonUp += delegate { ToggleCommandPanel(); };

            var canvas = new Canvas
            {
                Width = 280,
                Height = 280,
                IsHitTestVisible = false
            };

            _replyActivityRing = CreateActivityRing(260, CyanBrush, 3.2, out _replyActivityScale);
            _replyActivityRing.Effect = new DropShadowEffect { Color = Color.FromRgb(0, 255, 255), BlurRadius = 26, ShadowDepth = 0, Opacity = 0.9 };
            canvas.Children.Add(_replyActivityRing);
            _microphoneActivityRing = CreateActivityRing(222, CyanSoftBrush, 2.4, out _microphoneActivityScale);
            _microphoneActivityRing.Effect = new DropShadowEffect { Color = Color.FromRgb(98, 232, 255), BlurRadius = 20, ShadowDepth = 0, Opacity = 0.82 };
            canvas.Children.Add(_microphoneActivityRing);

            canvas.Children.Add(CreateRing(244, CyanBrush, 1.1, 0.73, 18, false, 0));
            _thinkingRing = (Ellipse)CreateRing(206, PurpleBrush, 1.8, 0.62, 12, true, 0.8);
            canvas.Children.Add(_thinkingRing);
            canvas.Children.Add(CreateRing(166, CyanSoftBrush, 0.9, 0.8, 9, true, 1.4));
            canvas.Children.Add(CreateRing(134, OrangeBrush, 1.2, 0.42, 6, true, 2.1));

            var crossHair = new Grid
            {
                Width = 230,
                Height = 230,
                IsHitTestVisible = false
            };
            crossHair.Children.Add(new Rectangle
            {
                Width = 1,
                Height = 230,
                Fill = CreateBrush(0, 126, 154),
                Opacity = 0.32,
                HorizontalAlignment = HorizontalAlignment.Center
            });
            crossHair.Children.Add(new Rectangle
            {
                Width = 230,
                Height = 1,
                Fill = CreateBrush(0, 126, 154),
                Opacity = 0.32,
                VerticalAlignment = VerticalAlignment.Center
            });

            var hub = new Border
            {
                Width = 114,
                Height = 114,
                CornerRadius = new CornerRadius(57),
                BorderBrush = CyanBrush,
                BorderThickness = new Thickness(1.5),
                Background = new RadialGradientBrush(
                    Color.FromRgb(46, 189, 224),
                    Color.FromRgb(4, 22, 38))
                {
                    GradientOrigin = new Point(0.38, 0.34),
                    Center = new Point(0.5, 0.5),
                    RadiusX = 0.62,
                    RadiusY = 0.62
                },
                Effect = new DropShadowEffect
                {
                    Color = Color.FromRgb(0, 255, 255),
                    BlurRadius = 30,
                    ShadowDepth = 0,
                    Opacity = 0.7
                },
                Child = CreateHubLabel()
            };
            _hubScale = new ScaleTransform(1, 1);
            hub.RenderTransform = _hubScale;
            hub.RenderTransformOrigin = new Point(0.5, 0.5);
            StartPulse(_hubScale, 1.0, 1.085, 1.55);

            host.Children.Add(canvas);
            host.Children.Add(crossHair);
            host.Children.Add(hub);
            return host;
        }

        private UIElement CreateHubLabel()
        {
            var stack = new StackPanel
            {
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center
            };
            stack.Children.Add(new TextBlock
            {
                Text = "J",
                FontSize = 42,
                FontWeight = FontWeights.Light,
                Foreground = Brushes.White,
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, -8, 0, -5)
            });
            stack.Children.Add(CreateText("CORE", 9, CyanBrush, FontWeights.SemiBold));
            return stack;
        }

        private UIElement CreateRing(double diameter, Brush stroke, double thickness, double opacity, double seconds, bool dashed, double delay)
        {
            var ring = new Ellipse
            {
                Width = diameter,
                Height = diameter,
                Stroke = stroke,
                StrokeThickness = thickness,
                Opacity = opacity,
                IsHitTestVisible = false
            };
            if (dashed)
            {
                ring.StrokeDashArray = new DoubleCollection { 1.1, 3.1 };
            }

            Canvas.SetLeft(ring, (280 - diameter) / 2);
            Canvas.SetTop(ring, (280 - diameter) / 2);

            var rotate = new RotateTransform(0);
            var scale = new ScaleTransform(1, 1);
            var transforms = new TransformGroup();
            transforms.Children.Add(rotate);
            transforms.Children.Add(scale);
            ring.RenderTransform = transforms;
            ring.RenderTransformOrigin = new Point(0.5, 0.5);

            var spin = new DoubleAnimation(0, 360, new Duration(TimeSpan.FromSeconds(seconds)))
            {
                RepeatBehavior = RepeatBehavior.Forever,
                BeginTime = TimeSpan.FromSeconds(delay)
            };
            rotate.BeginAnimation(RotateTransform.AngleProperty, spin);
            StartPulse(scale, 0.98, 1.035, Math.Max(1.3, seconds / 3.0));
            return ring;
        }

        private static Ellipse CreateActivityRing(double diameter, Brush stroke, double thickness, out ScaleTransform scale)
        {
            scale = new ScaleTransform(1, 1);
            var ring = new Ellipse
            {
                Width = diameter,
                Height = diameter,
                Stroke = stroke,
                StrokeThickness = thickness,
                Opacity = 0,
                IsHitTestVisible = false,
                RenderTransform = scale,
                RenderTransformOrigin = new Point(0.5, 0.5)
            };
            Canvas.SetLeft(ring, (280 - diameter) / 2);
            Canvas.SetTop(ring, (280 - diameter) / 2);
            return ring;
        }

        private Border BuildCommandPanel()
        {
            var panel = new Border
            {
                Background = SurfaceAltBrush,
                BorderBrush = CreateBrush(0, 92, 118),
                BorderThickness = new Thickness(1, 0, 0, 0),
                Padding = new Thickness(16, 12, 15, 12),
                Visibility = Visibility.Collapsed
            };

            var layout = new Grid();
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(31) });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(53) });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(13) });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(20) });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            var panelHeader = new Grid();
            panelHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            panelHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(40) });
            panelHeader.Children.Add(CreateText("КОМАНДНЫЙ КАНАЛ", 11, CyanBrush, FontWeights.SemiBold));
            var collapse = CreateButton("‹", CyanSoftBrush, Brushes.Transparent, Brushes.Transparent, 20);
            collapse.ToolTip = "Скрыть панель";
            collapse.Click += delegate { ToggleCommandPanel(); };
            Grid.SetColumn(collapse, 1);
            panelHeader.Children.Add(collapse);
            Grid.SetRow(panelHeader, 0);
            layout.Children.Add(panelHeader);

            var inputRow = new Grid();
            inputRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            inputRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(93) });
            inputRow.Children.Add(_commandBox);
            Grid.SetColumn(_sendButton, 1);
            _sendButton.Margin = new Thickness(8, 0, 0, 0);
            inputRow.Children.Add(_sendButton);
            Grid.SetRow(inputRow, 1);
            layout.Children.Add(inputRow);

            var replyCaption = CreateText("ОТВЕТ JARVIS", 9, MutedBrush, FontWeights.SemiBold);
            Grid.SetRow(replyCaption, 3);
            layout.Children.Add(replyCaption);

            var responseScroll = new ScrollViewer
            {
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Content = _replyText,
                Margin = new Thickness(0, 0, 1, 8)
            };
            Grid.SetRow(responseScroll, 4);
            layout.Children.Add(responseScroll);

            Grid.SetRow(_actionCard, 5);
            layout.Children.Add(_actionCard);

            panel.Child = layout;
            return panel;
        }

        private Border BuildActionCard()
        {
            var card = new Border
            {
                Background = CreateBrush(30, 20, 14),
                BorderBrush = OrangeBrush,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(9),
                Padding = new Thickness(10, 8, 10, 9),
                Margin = new Thickness(0, 3, 0, 0),
                Visibility = Visibility.Collapsed
            };

            var layout = new Grid();
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(7) });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(30) });
            layout.Children.Add(_actionTitleText);
            Grid.SetRow(_actionDetailText, 1);
            layout.Children.Add(_actionDetailText);
            Grid.SetRow(_confirmButton, 3);
            layout.Children.Add(_confirmButton);
            card.Child = layout;
            return card;
        }

        private static TextBox CreateCommandBox()
        {
            return new TextBox
            {
                Background = CreateBrush(2, 12, 21),
                Foreground = CreateBrush(232, 251, 255),
                BorderBrush = CreateBrush(0, 135, 157),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(10, 7, 8, 7),
                FontSize = 12,
                VerticalContentAlignment = VerticalAlignment.Center,
                MaxLength = 1200,
                ToolTip = "Напишите команду для локального JARVIS"
            };
        }

        private static Button CreateButton(string text, Brush foreground, Brush background, Brush border, double fontSize)
        {
            var button = new Button
            {
                Content = text,
                Foreground = foreground,
                Background = background,
                BorderBrush = border,
                BorderThickness = new Thickness(1),
                Padding = new Thickness(5, 2, 5, 2),
                FontSize = fontSize,
                FontWeight = FontWeights.SemiBold,
                Cursor = Cursors.Hand,
                FocusVisualStyle = null,
                VerticalContentAlignment = VerticalAlignment.Center,
                HorizontalContentAlignment = HorizontalAlignment.Center
            };
            return button;
        }

        private static ContextMenu CreateMicrophoneMenu()
        {
            return new ContextMenu
            {
                Background = SurfaceAltBrush,
                BorderBrush = CyanBrush,
                BorderThickness = new Thickness(1),
                Foreground = CyanSoftBrush,
                MinWidth = 260
            };
        }

        private static MenuItem CreateMicrophoneMenuItem(string header, string toolTip, bool isEnabled)
        {
            return new MenuItem
            {
                Header = header,
                ToolTip = toolTip,
                IsEnabled = isEnabled,
                Foreground = CyanSoftBrush,
                Background = SurfaceAltBrush,
                FontFamily = new FontFamily("Bahnschrift")
            };
        }

        private static TextBlock CreateText(string text, double size, Brush brush, FontWeight weight)
        {
            return new TextBlock
            {
                Text = text,
                FontSize = size,
                Foreground = brush,
                FontWeight = weight,
                TextTrimming = TextTrimming.CharacterEllipsis
            };
        }

        private async void OpenMicrophoneMenuAsync(object sender, RoutedEventArgs e)
        {
            if (_microphoneListLoading || !_senseSettingsWritable)
            {
                return;
            }

            _microphoneListLoading = true;
            _microphoneListError = false;
            UpdateMicrophoneButton();
            ShowMicrophoneLoadingMenu();
            SetStatus("MIC // ПОИСК");

            try
            {
                var microphones = await Task.Factory.StartNew(delegate { return ListMicrophones(); });
                PopulateMicrophoneMenu(microphones);
                _microphoneListError = false;
                SetStatus(microphones.Count == 0 ? "MIC // НЕТ ВХОДОВ" : "MIC // ГОТОВ");
            }
            catch (Exception)
            {
                _microphoneListError = true;
                ShowMicrophoneErrorMenu();
                SetStatus("MIC // ERROR");
            }
            finally
            {
                _microphoneListLoading = false;
                UpdateMicrophoneButton();
            }
        }

        private List<MicrophoneOption> ListMicrophones()
        {
            if (!File.Exists(_senseExecutablePath))
            {
                throw new FileNotFoundException("Jarvis Sense helper is not installed.");
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = _senseExecutablePath,
                Arguments = "--list-microphones",
                WorkingDirectory = System.IO.Path.GetDirectoryName(_senseExecutablePath),
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = new UTF8Encoding(false),
                StandardErrorEncoding = new UTF8Encoding(false)
            };

            using (var process = new Process())
            {
                process.StartInfo = startInfo;
                var standardOutput = new StringBuilder();
                var standardError = new StringBuilder();
                process.OutputDataReceived += delegate(object ignored, DataReceivedEventArgs output)
                {
                    if (output.Data != null && standardOutput.Length < 65536)
                    {
                        standardOutput.Append(output.Data);
                    }
                };
                process.ErrorDataReceived += delegate(object ignored, DataReceivedEventArgs error)
                {
                    if (error.Data != null && standardError.Length < 4096)
                    {
                        standardError.Append(error.Data);
                    }
                };

                if (!process.Start())
                {
                    throw new InvalidOperationException("Jarvis Sense helper did not start.");
                }

                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                if (!process.WaitForExit(5000))
                {
                    try
                    {
                        process.Kill();
                    }
                    catch (Exception)
                    {
                        // The helper may have exited between timeout detection and Kill.
                    }

                    throw new TimeoutException("Jarvis Sense microphone scan timed out.");
                }

                process.WaitForExit();
                if (process.ExitCode != 0)
                {
                    throw new InvalidOperationException("Jarvis Sense microphone scan failed.");
                }

                if (standardOutput.Length == 0 || standardOutput.Length >= 65536)
                {
                    throw new InvalidOperationException("Jarvis Sense returned no usable microphone list.");
                }

                return ParseMicrophoneList(standardOutput.ToString());
            }
        }

        private static List<MicrophoneOption> ParseMicrophoneList(string json)
        {
            var payload = ParseJsonObject(RemoveUtf8Bom(json));
            if (payload == null)
            {
                throw new InvalidOperationException("Jarvis Sense returned invalid microphone JSON.");
            }

            int schemaVersion;
            if (!TryGetInteger(payload, "schemaVersion", out schemaVersion) || schemaVersion != 1)
            {
                throw new InvalidOperationException("Jarvis Sense microphone schema is unsupported.");
            }

            int? defaultDeviceId;
            if (!TryGetOptionalMicrophoneDevice(payload, "defaultDeviceId", out defaultDeviceId))
            {
                throw new InvalidOperationException("Jarvis Sense default microphone is invalid.");
            }

            object rawMicrophones;
            var rawList = payload.TryGetValue("microphones", out rawMicrophones) ? rawMicrophones as object[] : null;
            if (rawList == null)
            {
                throw new InvalidOperationException("Jarvis Sense microphone list is invalid.");
            }

            var result = new List<MicrophoneOption>();
            foreach (var rawMicrophone in rawList)
            {
                var microphone = rawMicrophone as Dictionary<string, object>;
                int id;
                if (microphone == null
                    || !TryGetInteger(microphone, "id", out id)
                    || id < 0)
                {
                    continue;
                }

                var name = CleanMicrophoneText(GetString(microphone, "name"), 120);
                if (string.IsNullOrWhiteSpace(name))
                {
                    continue;
                }

                var hostApi = CleanMicrophoneText(GetString(microphone, "hostApi"), 80);
                var isDefault = GetBoolean(microphone, "isDefault")
                    || (defaultDeviceId.HasValue && defaultDeviceId.Value == id);
                result.Add(new MicrophoneOption(id, name, hostApi, isDefault));
            }

            return result;
        }

        private void ShowMicrophoneLoadingMenu()
        {
            _microphoneMenu.Items.Clear();
            _microphoneMenu.Items.Add(CreateMicrophoneMenuItem(
                "MIC // ПОИСК УСТРОЙСТВ...",
                "JARVIS спрашивает список только у локального помощника.",
                false));
            _microphoneMenu.PlacementTarget = _microphoneButton;
            _microphoneMenu.IsOpen = true;
        }

        private void ShowMicrophoneErrorMenu()
        {
            _microphoneMenu.Items.Clear();
            _microphoneMenu.Items.Add(CreateMicrophoneMenuItem(
                "MIC // СПИСОК НЕДОСТУПЕН",
                "Проверьте, что локальный Jarvis Sense установлен и запущен.",
                false));
            _microphoneMenu.PlacementTarget = _microphoneButton;
            _microphoneMenu.IsOpen = true;
        }

        private void PopulateMicrophoneMenu(List<MicrophoneOption> microphones)
        {
            _microphoneMenu.Items.Clear();

            var auto = CreateMicrophoneMenuItem(
                "AUTO // СИСТЕМНЫЙ МИКРОФОН",
                "Использовать микрофон Windows по умолчанию.",
                true);
            auto.IsCheckable = true;
            auto.IsChecked = !_microphoneDevice.HasValue;
            auto.Click += delegate { SelectMicrophone(null); };
            _microphoneMenu.Items.Add(auto);

            if (microphones.Count > 0)
            {
                _microphoneMenu.Items.Add(new Separator());
            }

            foreach (var microphone in microphones)
            {
                var selected = microphone;
                var header = (selected.IsDefault ? "✓ " : string.Empty) + selected.Name;
                var item = CreateMicrophoneMenuItem(
                    header,
                    string.IsNullOrWhiteSpace(selected.HostApi) ? "Локальное устройство ввода." : selected.HostApi,
                    true);
                item.IsCheckable = true;
                item.IsChecked = _microphoneDevice.HasValue && _microphoneDevice.Value == selected.Id;
                item.Click += delegate { SelectMicrophone(selected); };
                _microphoneMenu.Items.Add(item);
            }

            _microphoneMenu.PlacementTarget = _microphoneButton;
            _microphoneMenu.IsOpen = true;

            if (_microphoneDevice.HasValue)
            {
                foreach (var microphone in microphones)
                {
                    if (microphone.Id == _microphoneDevice.Value)
                    {
                        _microphoneDeviceCaption = microphone.Name;
                        break;
                    }
                }
            }
        }

        private void SelectMicrophone(MicrophoneOption microphone)
        {
            if (!_senseSettingsWritable)
            {
                SetStatus("SENSE // CONFIG ERROR");
                return;
            }

            var previousDevice = _microphoneDevice;
            var previousCaption = _microphoneDeviceCaption;
            _microphoneDevice = microphone == null ? (int?)null : microphone.Id;
            _microphoneDeviceCaption = microphone == null ? "AUTO" : microphone.Name;
            _microphoneListError = false;

            try
            {
                SaveSenseSettings();
                UpdateSenseButtons();
                UpdateMicrophoneButton();
                SetStatus(_microphoneDevice.HasValue ? "MIC // ВЫБРАН" : "MIC // AUTO");
            }
            catch (Exception)
            {
                _microphoneDevice = previousDevice;
                _microphoneDeviceCaption = previousCaption;
                _senseSettingsWritable = false;
                UpdateSenseButtons();
                UpdateMicrophoneButton();
                SetStatus("SENSE // CONFIG ERROR");
            }
        }

        private void UpdateMicrophoneButton()
        {
            if (_microphoneButton == null)
            {
                return;
            }

            _microphoneButton.IsEnabled = _senseSettingsWritable && !_microphoneListLoading;
            if (!_senseSettingsWritable)
            {
                _microphoneButton.Content = "MIC // LOCK";
                _microphoneButton.Foreground = OrangeBrush;
                _microphoneButton.BorderBrush = OrangeBrush;
                _microphoneButton.ToolTip = "Настройки микрофона недоступны: файл не был изменён.";
                return;
            }

            if (_microphoneListLoading)
            {
                _microphoneButton.Content = "MIC // SCAN";
                _microphoneButton.Foreground = CyanSoftBrush;
                _microphoneButton.BorderBrush = CyanBrush;
                _microphoneButton.ToolTip = "JARVIS получает список локальных устройств ввода.";
                return;
            }

            if (_microphoneListError)
            {
                _microphoneButton.Content = "MIC // ERROR";
                _microphoneButton.Foreground = OrangeBrush;
                _microphoneButton.BorderBrush = OrangeBrush;
                _microphoneButton.ToolTip = "Список микрофонов недоступен. Нажмите, чтобы повторить.";
                return;
            }

            _microphoneButton.Content = _microphoneDevice.HasValue
                ? "MIC // " + ShortMicrophoneCaption(_microphoneDeviceCaption, _microphoneDevice.Value)
                : "MIC // AUTO";
            _microphoneButton.Foreground = _microphoneDevice.HasValue ? GreenBrush : CyanSoftBrush;
            _microphoneButton.BorderBrush = _microphoneDevice.HasValue ? GreenBrush : CreateBrush(0, 132, 154);
            _microphoneButton.ToolTip = _microphoneDevice.HasValue
                ? "Выбран локальный микрофон: " + CleanMicrophoneText(_microphoneDeviceCaption, 120)
                : "Используется микрофон Windows по умолчанию.";
        }

        private static string ShortMicrophoneCaption(string caption, int deviceId)
        {
            var clean = CleanMicrophoneText(caption, 12);
            if (string.IsNullOrWhiteSpace(clean) || string.Equals(clean, "AUTO", StringComparison.OrdinalIgnoreCase))
            {
                return "#" + deviceId.ToString(CultureInfo.InvariantCulture);
            }

            return clean;
        }

        private static string CleanMicrophoneText(string value, int limit)
        {
            var clean = (value ?? string.Empty)
                .Replace('\0', ' ')
                .Replace('\r', ' ')
                .Replace('\n', ' ')
                .Trim();
            return clean.Length <= limit ? clean : clean.Substring(0, Math.Max(1, limit - 1)) + "…";
        }

        private static string RemoveUtf8Bom(string value)
        {
            if (!string.IsNullOrEmpty(value) && value[0] == '\ufeff')
            {
                return value.Substring(1);
            }

            return value;
        }

        private void ToggleVoiceSense(object sender, RoutedEventArgs e)
        {
            ToggleSense(true);
        }

        private void ToggleVisionSense(object sender, RoutedEventArgs e)
        {
            ToggleSense(false);
        }

        private void ToggleSense(bool voice)
        {
            if (!_senseSettingsWritable)
            {
                SetStatus("SENSE // CONFIG ERROR");
                return;
            }

            var previousVoice = _voiceSenseEnabled;
            var previousVision = _visionSenseEnabled;
            if (voice)
            {
                _voiceSenseEnabled = !_voiceSenseEnabled;
            }
            else
            {
                _visionSenseEnabled = !_visionSenseEnabled;
            }

            try
            {
                SaveSenseSettings();
                UpdateSenseButtons();
                UpdateMicrophoneButton();
                SetStatus(voice
                    ? (_voiceSenseEnabled ? "VOICE // ACTIVE" : "VOICE // OFF")
                    : (_visionSenseEnabled ? "VISION // ACTIVE" : "VISION // OFF"));
            }
            catch (Exception)
            {
                _voiceSenseEnabled = previousVoice;
                _visionSenseEnabled = previousVision;
                _senseSettingsWritable = false;
                UpdateSenseButtons();
                UpdateMicrophoneButton();
                SetStatus("SENSE // CONFIG ERROR");
            }
        }

        private void LoadSenseSettings()
        {
            _voiceSenseEnabled = false;
            _visionSenseEnabled = false;
            _senseSettingsWritable = true;

            try
            {
                if (!File.Exists(_senseSettingsPath))
                {
                    return;
                }

                var payload = ParseJsonObject(File.ReadAllText(_senseSettingsPath, Encoding.UTF8));
                bool voiceEnabled;
                bool visionEnabled;
                int? microphoneDevice;
                if (!TryReadSenseSettings(payload, out voiceEnabled, out visionEnabled, out microphoneDevice))
                {
                    _senseSettingsWritable = false;
                    return;
                }

                _voiceSenseEnabled = voiceEnabled;
                _visionSenseEnabled = visionEnabled;
                _microphoneDevice = microphoneDevice;
                _microphoneDeviceCaption = microphoneDevice.HasValue
                    ? "#" + microphoneDevice.Value.ToString(CultureInfo.InvariantCulture)
                    : "AUTO";
            }
            catch (Exception)
            {
                _senseSettingsWritable = false;
            }
        }

        private void SaveSenseSettings()
        {
            if (!_senseSettingsWritable)
            {
                throw new InvalidOperationException("Sense settings are unavailable.");
            }

            Dictionary<string, object> payload;
            if (File.Exists(_senseSettingsPath))
            {
                payload = ParseJsonObject(File.ReadAllText(_senseSettingsPath, Encoding.UTF8));
                bool persistedVoice;
                bool persistedVision;
                int? persistedMicrophone;
                if (!TryReadSenseSettings(payload, out persistedVoice, out persistedVision, out persistedMicrophone))
                {
                    _senseSettingsWritable = false;
                    throw new IOException("Sense settings are invalid.");
                }
            }
            else
            {
                payload = new Dictionary<string, object>();
            }

            payload["voiceEnabled"] = _voiceSenseEnabled;
            payload["visionEnabled"] = _visionSenseEnabled;
            payload["microphoneDevice"] = _microphoneDevice.HasValue
                ? (object)_microphoneDevice.Value
                : null;

            var directory = System.IO.Path.GetDirectoryName(_senseSettingsPath);
            if (string.IsNullOrWhiteSpace(directory))
            {
                throw new IOException("Sense settings directory is unavailable.");
            }

            Directory.CreateDirectory(directory);
            var temporaryPath = _senseSettingsPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllText(temporaryPath, Serializer.Serialize(payload), new UTF8Encoding(false));
                if (File.Exists(_senseSettingsPath))
                {
                    File.Replace(temporaryPath, _senseSettingsPath, null);
                }
                else
                {
                    File.Move(temporaryPath, _senseSettingsPath);
                }
            }
            finally
            {
                try
                {
                    if (File.Exists(temporaryPath))
                    {
                        File.Delete(temporaryPath);
                    }
                }
                catch (Exception)
                {
                    // A uniquely-named temporary file is harmless; the main settings file remains untouched.
                }
            }
        }

        private void UpdateSenseButtons()
        {
            if (_voiceToggleButton == null || _visionToggleButton == null)
            {
                return;
            }

            _voiceToggleButton.Content = _voiceSenseEnabled ? "VOICE // ON" : "VOICE // OFF";
            _voiceToggleButton.Foreground = _voiceSenseEnabled ? GreenBrush : MutedBrush;
            _voiceToggleButton.BorderBrush = _voiceSenseEnabled ? GreenBrush : CreateBrush(0, 92, 118);
            _voiceToggleButton.IsEnabled = _senseSettingsWritable;
            _voiceToggleButton.ToolTip = _senseSettingsWritable
                ? "Локальная фраза «Джарвис»: " + (_voiceSenseEnabled ? "включена" : "выключена")
                : "Настройки голоса недоступны: файл не был изменён.";

            _visionToggleButton.Content = _visionSenseEnabled ? "VISION // ON" : "VISION // OFF";
            _visionToggleButton.Foreground = _visionSenseEnabled ? PurpleBrush : MutedBrush;
            _visionToggleButton.BorderBrush = _visionSenseEnabled ? PurpleBrush : CreateBrush(0, 92, 118);
            _visionToggleButton.IsEnabled = _senseSettingsWritable;
            _visionToggleButton.ToolTip = _senseSettingsWritable
                ? "Локальный анализ экрана: " + (_visionSenseEnabled ? "включён" : "выключен")
                : "Настройки зрения недоступны: файл не был изменён.";
        }

        private static bool TryReadSenseSettings(
            Dictionary<string, object> source,
            out bool voiceEnabled,
            out bool visionEnabled,
            out int? microphoneDevice)
        {
            voiceEnabled = false;
            visionEnabled = false;
            microphoneDevice = null;
            if (source == null)
            {
                return false;
            }

            return TryGetOptionalSenseBoolean(source, "voiceEnabled", out voiceEnabled)
                && TryGetOptionalSenseBoolean(source, "visionEnabled", out visionEnabled)
                && TryGetOptionalMicrophoneDevice(source, "microphoneDevice", out microphoneDevice);
        }

        private static bool TryGetOptionalSenseBoolean(Dictionary<string, object> source, string name, out bool value)
        {
            value = false;
            object raw;
            if (!source.TryGetValue(name, out raw))
            {
                return true;
            }

            if (raw is bool)
            {
                value = (bool)raw;
                return true;
            }

            return false;
        }

        private static bool TryGetOptionalMicrophoneDevice(
            Dictionary<string, object> source,
            string name,
            out int? deviceId)
        {
            deviceId = null;
            object raw;
            if (!source.TryGetValue(name, out raw) || raw == null)
            {
                return true;
            }

            var mode = raw as string;
            if (mode != null)
            {
                return string.Equals(mode.Trim(), "auto", StringComparison.OrdinalIgnoreCase);
            }

            int parsed;
            if (!TryGetIntegerValue(raw, out parsed) || parsed < 0)
            {
                return false;
            }

            deviceId = parsed;
            return true;
        }

        private static bool TryGetInteger(Dictionary<string, object> source, string name, out int value)
        {
            value = 0;
            object raw;
            return source != null && source.TryGetValue(name, out raw) && TryGetIntegerValue(raw, out value);
        }

        private static bool TryGetIntegerValue(object raw, out int value)
        {
            value = 0;
            if (raw is int)
            {
                value = (int)raw;
                return true;
            }

            if (raw is long)
            {
                var longValue = (long)raw;
                if (longValue < int.MinValue || longValue > int.MaxValue)
                {
                    return false;
                }

                value = (int)longValue;
                return true;
            }

            return false;
        }

        private void DragWindow(object sender, MouseButtonEventArgs e)
        {
            if (e.ChangedButton != MouseButton.Left || IsInteractiveHeaderSource(e.OriginalSource as DependencyObject))
            {
                return;
            }

            try
            {
                DragMove();
                e.Handled = true;
            }
            catch (InvalidOperationException)
            {
                // Windows may reject DragMove while the desktop is changing state.
            }
        }

        private static bool IsInteractiveHeaderSource(DependencyObject source)
        {
            var current = source;
            while (current != null)
            {
                if (current is Button || current is TextBox || current is MenuItem)
                {
                    return true;
                }

                var visual = current as Visual;
                current = visual != null
                    ? VisualTreeHelper.GetParent(visual)
                    : LogicalTreeHelper.GetParent(current);
            }

            return false;
        }

        private void ToggleTopmost(object sender, RoutedEventArgs e)
        {
            Topmost = !Topmost;
            _pinButton.Content = Topmost ? "PIN ON" : "PIN OFF";
            SetStatus(Topmost ? "WINDOW // СВЕРХУ" : "WINDOW // ОБЫЧНО");
        }

        private void ToggleCommandPanel()
        {
            _panelOpen = !_panelOpen;
            _commandPanel.Visibility = _panelOpen ? Visibility.Visible : Visibility.Collapsed;
            Width = _panelOpen ? ExpandedWidth : CompactWidth;

            if (_panelOpen)
            {
                Dispatcher.BeginInvoke(new Action(delegate { _commandBox.Focus(); }));
            }
        }

        private void CommandTextChanged(object sender, TextChangedEventArgs e)
        {
            UpdateControls();
        }

        private void CommandBoxKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.None)
            {
                SendChatAsync(sender, e);
                e.Handled = true;
            }
        }

        private async void SendChatAsync(object sender, RoutedEventArgs e)
        {
            var message = (_commandBox.Text ?? string.Empty).Trim();
            if (_busy || message.Length == 0)
            {
                return;
            }

            if (message.Length > 1200)
            {
                ShowError("Команда длиннее 1200 символов. Сократите её.");
                return;
            }

            SetBusy(true);
            HideAction();
            SetStatus(ActivityCaption(message));
            _replyText.Text = "ВЫ // " + message + "\n\nJARVIS // выполняю и проверяю...";

            try
            {
                var response = await PostJsonAsync(
                    "api/chat",
                    new Dictionary<string, object> { { "message", message } });
                var reply = GetString(response, "reply");
                if (string.IsNullOrWhiteSpace(reply))
                {
                    throw new ApiException("Локальное ядро вернуло пустой ответ.");
                }

                _commandBox.Clear();
                _replyText.Text = "ВЫ // " + message + "\n\nJARVIS // " + reply;
                var responseAction = GetObject(response, "action");
                PresentAction(responseAction);
                SetStatus(responseAction != null ? "CORE // ЖДУ ПОДТВЕРЖДЕНИЕ" : (IsComputerCommand(message) ? "CORE // ГОТОВО · ПРОВЕРЕНО" : "JARVIS // ОТВЕЧАЮ"));
                Speak(reply);
            }
            catch (Exception exception)
            {
                ShowError(ToUserError(exception));
            }
            finally
            {
                SetBusy(false);
            }
        }

        private async void ConfirmActionAsync(object sender, RoutedEventArgs e)
        {
            var action = _pendingAction;
            if (_busy || action == null)
            {
                return;
            }

            _pendingAction = null;
            _confirmButton.IsEnabled = false;
            _actionDetailText.Text = "Подтверждение отправлено в локальный safety gate...";
            SetBusy(true);
            SetStatus("CORE // ВЫПОЛНЕНИЕ");

            try
            {
                var response = await PostJsonAsync(
                    "api/actions/execute",
                    new Dictionary<string, object> { { "token", action.Token } });
                if (!GetBoolean(response, "ok"))
                {
                    throw new ApiException("Локальное ядро не подтвердило выполнение действия.");
                }

                var result = GetString(response, "message");
                if (string.IsNullOrWhiteSpace(result))
                {
                    throw new ApiException("Локальное ядро не вернуло результат действия.");
                }

                _replyText.Text = result;
                _actionCard.Visibility = Visibility.Collapsed;
                SetStatus("CORE // ГОТОВО");
                Speak(result);
            }
            catch (Exception exception)
            {
                _actionCard.Visibility = Visibility.Collapsed;
                ShowError(ToUserError(exception));
            }
            finally
            {
                SetBusy(false);
            }
        }

        private void PresentAction(Dictionary<string, object> action)
        {
            if (action == null)
            {
                HideAction();
                return;
            }

            var token = GetString(action, "token");
            var label = GetString(action, "label");
            var detail = GetString(action, "detail");
            var risk = GetString(action, "risk");
            Guid parsedToken;
            if (!Guid.TryParse(token, out parsedToken) || string.IsNullOrWhiteSpace(label) || !IsKnownRisk(risk))
            {
                HideAction();
                _replyText.Text += Environment.NewLine + Environment.NewLine
                    + "Нераспознанное предложение действия не было показано для подтверждения.";
                SetStatus("CORE // ЗАЩИТА");
                return;
            }

            _pendingAction = new PendingAction(token, label, detail, risk);
            _actionTitleText.Text = "ТРЕБУЕТ ПОДТВЕРЖДЕНИЯ // " + label;
            _actionDetailText.Text = RiskCaption(risk) + " · "
                + (string.IsNullOrWhiteSpace(detail) ? "Разрешённое локальным ядром действие." : detail)
                + Environment.NewLine + "Токен одноразовый; повтор требует новой команды.";
            _confirmButton.Content = "ПОДТВЕРДИТЬ";
            _actionCard.Visibility = Visibility.Visible;
            UpdateControls();
        }

        private void HideAction()
        {
            _pendingAction = null;
            _actionCard.Visibility = Visibility.Collapsed;
            UpdateControls();
        }

        private async void PollSenseVisualState(object sender, EventArgs e)
        {
            if (_visualPollBusy)
            {
                return;
            }

            _visualPollBusy = true;
            try
            {
                using (var response = await NeuralTtsHttp.GetAsync("state"))
                {
                    if (!response.IsSuccessStatusCode)
                    {
                        UpdateCoreVisualState(false, 0.0);
                        return;
                    }

                    var payload = ParseJsonObject(await response.Content.ReadAsStringAsync());
                    ApplySenseFeed(payload);
                    UpdateCoreVisualState(GetBoolean(payload, "speaking"), GetDouble(payload, "microphoneLevel"), GetString(payload, "activity"));
                }
            }
            catch (Exception)
            {
                UpdateCoreVisualState(false, 0.0);
            }
            finally
            {
                _visualPollBusy = false;
            }
        }

        private void UpdateCoreVisualState(bool speaking, double microphoneLevel, string activity = null)
        {
            if (_hubScale == null || _microphoneActivityRing == null || _replyActivityRing == null || _thinkingRing == null)
            {
                return;
            }

            microphoneLevel = Math.Max(0.0, Math.Min(1.0, microphoneLevel));
            var state = speaking ? "speaking" : (microphoneLevel > 0.055 ? "listening" : (_busy || string.Equals(activity, "processing", StringComparison.OrdinalIgnoreCase) ? "thinking" : "idle"));
            _microphoneActivityRing.Opacity = state == "listening" ? 0.18 + (microphoneLevel * 0.82) : 0.0;
            _microphoneActivityScale.ScaleX = 1.0 + (microphoneLevel * 0.16);
            _microphoneActivityScale.ScaleY = 1.0 + (microphoneLevel * 0.16);
            _replyActivityRing.Opacity = state == "speaking" ? 0.9 : 0.0;
            _thinkingRing.Opacity = state == "thinking" ? 0.94 : 0.62;

            if (state == "speaking")
            {
                _voiceText.Text = "NEURAL // ГОВОРЮ";
                _voiceText.Foreground = GreenBrush;
            }
            else if (state == "listening")
            {
                _voiceText.Text = "MIC // СЛЫШУ";
                _voiceText.Foreground = CyanSoftBrush;
            }
            else if (!_busy && !_voiceText.Text.StartsWith("SAPI", StringComparison.Ordinal))
            {
                _voiceText.Text = "NEURAL // ГОТОВ";
                _voiceText.Foreground = MutedBrush;
            }

            if (string.Equals(state, _coreVisualState, StringComparison.Ordinal))
            {
                return;
            }

            _coreVisualState = state;
            if (state == "speaking")
            {
                StartPulse(_hubScale, 1.03, 1.16, 0.42);
                StartPulse(_replyActivityScale, 0.96, 1.08, 0.52);
            }
            else if (state == "listening")
            {
                StartPulse(_hubScale, 1.0, 1.10, 0.72);
            }
            else if (state == "thinking")
            {
                StartPulse(_hubScale, 0.99, 1.09, 0.58);
            }
            else
            {
                StartPulse(_hubScale, 1.0, 1.085, 1.55);
            }
        }

        private void SetBusy(bool busy)
        {
            _busy = busy;
            UpdateCoreVisualState(false, 0.0);
            UpdateControls();
        }

        private void UpdateControls()
        {
            if (_sendButton == null || _confirmButton == null || _commandBox == null)
            {
                return;
            }

            _commandBox.IsEnabled = !_busy;
            _sendButton.IsEnabled = !_busy && !string.IsNullOrWhiteSpace(_commandBox.Text);
            _confirmButton.IsEnabled = !_busy && _pendingAction != null;
        }

        private static bool IsComputerCommand(string message)
        {
            var input = (message ?? string.Empty).Trim().ToLowerInvariant();
            var prefixes = new[] { "открой", "запусти", "включи", "open", "закрой", "закрыть", "выключи", "close", "нажми", "напиши", "введи", "клик", "перемести", "прокрути", "найди" };
            foreach (var prefix in prefixes)
            {
                if (input == prefix || input.StartsWith(prefix + " ", StringComparison.Ordinal)) return true;
            }
            return false;
        }

        private static string ActivityCaption(string message)
        {
            var input = (message ?? string.Empty).Trim().ToLowerInvariant();
            if (input.StartsWith("посмотри", StringComparison.Ordinal) || input.StartsWith("глянь", StringComparison.Ordinal) || input.Contains("на экране")) return "VISION // СМОТРЮ · АНАЛИЗИРУЮ";
            if (input.StartsWith("закрой", StringComparison.Ordinal) || input.StartsWith("закрыть", StringComparison.Ordinal) || input.StartsWith("close", StringComparison.Ordinal)) return "CORE // ИЩУ ОКНО · ЗАКРЫВАЮ";
            if (input.StartsWith("открой", StringComparison.Ordinal) || input.StartsWith("запусти", StringComparison.Ordinal) || input.StartsWith("open", StringComparison.Ordinal)) return "CORE // ИЩУ ПРИЛОЖЕНИЕ · ЗАПУСКАЮ";
            if (IsComputerCommand(message)) return "CORE // ВЫПОЛНЯЮ · ПРОВЕРЯЮ";
            return "JARVIS // ДУМАЮ НАД ОТВЕТОМ";
        }

        private void ApplySenseFeed(Dictionary<string, object> payload)
        {
            var command = GetString(payload, "lastCommand");
            var reply = GetString(payload, "lastReply");
            var activity = GetString(payload, "activity");
            var changed = false;
            if (!string.IsNullOrWhiteSpace(command) && !string.Equals(command, _lastSenseCommand, StringComparison.Ordinal))
            {
                _lastSenseCommand = command;
                _lastSenseReply = string.Empty;
                _replyText.Text = "ВЫ // " + command + "\n\nJARVIS // выполняю и проверяю...";
                SetStatus(ActivityCaption(command));
                changed = true;
            }
            if (!string.IsNullOrWhiteSpace(reply) && !string.Equals(reply, _lastSenseReply, StringComparison.Ordinal))
            {
                _lastSenseReply = reply;
                _replyText.Text = (string.IsNullOrWhiteSpace(_lastSenseCommand) ? string.Empty : "ВЫ // " + _lastSenseCommand + "\n\n") + "JARVIS // " + reply;
                SetStatus(string.Equals(activity, "awaiting-confirmation", StringComparison.OrdinalIgnoreCase) ? "CORE // ЖДУ ПОДТВЕРЖДЕНИЕ" : "CORE // ГОТОВО · ОТВЕЧАЮ");
                changed = true;
            }
            if (changed && !_panelOpen)
            {
                ToggleCommandPanel();
            }
        }

        private void SetStatus(string text)
        {
            _statusText.Text = text;
            _statusText.Foreground = text.IndexOf("ОШИБ", StringComparison.OrdinalIgnoreCase) >= 0
                ? OrangeBrush
                : text.IndexOf("ГОТОВО", StringComparison.OrdinalIgnoreCase) >= 0
                    ? GreenBrush
                    : text.IndexOf("ДУМАЮ", StringComparison.OrdinalIgnoreCase) >= 0 || text.IndexOf("ВЫПОЛН", StringComparison.OrdinalIgnoreCase) >= 0
                        ? PurpleBrush
                        : CyanSoftBrush;
        }

        private void ShowError(string message)
        {
            HideAction();
            _replyText.Text = message;
            SetStatus("CORE // ОШИБКА");
        }

        private void ConfigureSpeech()
        {
            try
            {
                var speaker = new SpeechSynthesizer();
                foreach (var installed in speaker.GetInstalledVoices())
                {
                    if (installed.Enabled
                        && installed.VoiceInfo.Culture != null
                        && string.Equals(
                            installed.VoiceInfo.Culture.TwoLetterISOLanguageName,
                            "ru",
                            StringComparison.OrdinalIgnoreCase))
                    {
                        speaker.SelectVoice(installed.VoiceInfo.Name);
                        _speaker = speaker;
                        _hasRussianVoice = true;
                        return;
                    }
                }

                speaker.Dispose();
            }
            catch (Exception)
            {
                _speaker = null;
                _hasRussianVoice = false;
            }
        }

        private async void Speak(string text)
        {
            if (string.IsNullOrWhiteSpace(text))
            {
                return;
            }

            try
            {
                var payload = Serializer.Serialize(new Dictionary<string, object> { { "text", text } });
                using (var content = new StringContent(payload, Encoding.UTF8, "application/json"))
                using (var response = await NeuralTtsHttp.PostAsync("speak", content))
                {
                    if (response.IsSuccessStatusCode)
                    {
                        _voiceText.Text = "NEURAL // ГОТОВ";
                        _voiceText.Foreground = MutedBrush;
                        return;
                    }
                }
            }
            catch (Exception)
            {
                // The local bridge may be restarting; use the Windows voice below.
            }

            SpeakWithWindowsFallback(text);
        }

        private void SpeakWithWindowsFallback(string text)
        {
            if (!_hasRussianVoice || _speaker == null)
            {
                _voiceText.Text = "ГОЛОС // НЕДОСТУПЕН";
                _voiceText.Foreground = OrangeBrush;
                return;
            }

            try
            {
                _speaker.SpeakAsyncCancelAll();
                _speaker.SpeakAsync(text);
                _voiceText.Text = "SAPI FALLBACK // ГОВОРЮ";
                _voiceText.Foreground = GreenBrush;
            }
            catch (Exception)
            {
                _voiceText.Text = "SAPI RU // ОШИБКА";
                _voiceText.Foreground = OrangeBrush;
            }
        }

        private void DisposeSpeech(object sender, EventArgs e)
        {
            if (_visualTimer != null)
            {
                _visualTimer.Stop();
            }

            if (_speaker == null)
            {
                return;
            }

            try
            {
                _speaker.SpeakAsyncCancelAll();
                _speaker.Dispose();
            }
            catch (Exception)
            {
                // Closing the pet must not be blocked by a speech subsystem failure.
            }
        }

        private void PositionNearWorkArea(object sender, RoutedEventArgs e)
        {
            var workArea = SystemParameters.WorkArea;
            Left = Math.Max(workArea.Left + 16, workArea.Right - Width - 28);
            Top = Math.Max(workArea.Top + 16, workArea.Bottom - Height - 52);
        }

        private static async Task<Dictionary<string, object>> PostJsonAsync(string relativePath, Dictionary<string, object> body)
        {
            var requestJson = Serializer.Serialize(body);
            using (var content = new StringContent(requestJson, Encoding.UTF8, "application/json"))
            using (var response = await Http.PostAsync(relativePath, content))
            {
                var responseText = await response.Content.ReadAsStringAsync();
                var payload = ParseJsonObject(responseText);
                if (!response.IsSuccessStatusCode)
                {
                    var error = GetString(payload, "error");
                    if (string.IsNullOrWhiteSpace(error))
                    {
                        error = "Локальное ядро вернуло HTTP " + ((int)response.StatusCode).ToString(CultureInfo.InvariantCulture) + ".";
                    }

                    throw new ApiException(error);
                }

                if (payload == null)
                {
                    throw new ApiException("Локальное ядро вернуло некорректный JSON.");
                }

                return payload;
            }
        }

        private static Dictionary<string, object> ParseJsonObject(string json)
        {
            if (string.IsNullOrWhiteSpace(json))
            {
                return null;
            }

            try
            {
                return Serializer.DeserializeObject(json) as Dictionary<string, object>;
            }
            catch (ArgumentException)
            {
                return null;
            }
        }

        private static string GetString(Dictionary<string, object> source, string name)
        {
            if (source == null)
            {
                return string.Empty;
            }

            object value;
            if (!source.TryGetValue(name, out value) || value == null)
            {
                return string.Empty;
            }

            return Convert.ToString(value, CultureInfo.InvariantCulture).Trim();
        }

        private static bool GetBoolean(Dictionary<string, object> source, string name)
        {
            if (source == null)
            {
                return false;
            }

            object value;
            if (!source.TryGetValue(name, out value) || value == null)
            {
                return false;
            }

            if (value is bool)
            {
                return (bool)value;
            }

            bool parsed;
            return bool.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), out parsed) && parsed;
        }

        private static double GetDouble(Dictionary<string, object> source, string name)
        {
            if (source == null)
            {
                return 0.0;
            }

            object value;
            if (!source.TryGetValue(name, out value) || value == null)
            {
                return 0.0;
            }

            double parsed;
            return double.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out parsed) ? parsed : 0.0;
        }

        private static Dictionary<string, object> GetObject(Dictionary<string, object> source, string name)
        {
            if (source == null)
            {
                return null;
            }

            object value;
            return source.TryGetValue(name, out value) ? value as Dictionary<string, object> : null;
        }

        private static string ToUserError(Exception exception)
        {
            var apiError = exception as ApiException;
            if (apiError != null)
            {
                return apiError.Message;
            }

            if (exception is TaskCanceledException)
            {
                return "Локальное ядро не ответило за 15 секунд.";
            }

            if (exception is HttpRequestException)
            {
                return "Локальное ядро на 127.0.0.1:3791 недоступно. Запустите JARVIS и повторите.";
            }

            return "Ошибка связи с локальным ядром: " + exception.Message;
        }

        private static bool IsKnownRisk(string risk)
        {
            return string.Equals(risk, "normal", StringComparison.Ordinal)
                || string.Equals(risk, "attention", StringComparison.Ordinal)
                || string.Equals(risk, "sensitive", StringComparison.Ordinal);
        }

        private static string RiskCaption(string risk)
        {
            if (string.Equals(risk, "sensitive", StringComparison.Ordinal))
            {
                return "ЧУВСТВИТЕЛЬНОЕ ДЕЙСТВИЕ";
            }

            if (string.Equals(risk, "attention", StringComparison.Ordinal))
            {
                return "ТРЕБУЕТ ВНИМАНИЯ";
            }

            return "РАЗРЕШЁННОЕ ДЕЙСТВИЕ";
        }

        private static void StartPulse(ScaleTransform scale, double from, double to, double seconds)
        {
            var x = new DoubleAnimation(from, to, new Duration(TimeSpan.FromSeconds(seconds)))
            {
                AutoReverse = true,
                RepeatBehavior = RepeatBehavior.Forever
            };
            var y = x.Clone();
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, x);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, y);
        }

        private static Brush CreateBrush(byte red, byte green, byte blue)
        {
            var brush = new SolidColorBrush(Color.FromRgb(red, green, blue));
            brush.Freeze();
            return brush;
        }

        private static HttpClient CreateHttpClient()
        {
            var handler = new HttpClientHandler
            {
                UseProxy = false
            };
            var client = new HttpClient(handler)
            {
                BaseAddress = new Uri(LocalService),
                Timeout = TimeSpan.FromSeconds(15)
            };
            return client;
        }

        private static HttpClient CreateTtsHttpClient()
        {
            var handler = new HttpClientHandler
            {
                UseProxy = false
            };
            var client = new HttpClient(handler)
            {
                BaseAddress = new Uri(LocalTtsService),
                Timeout = TimeSpan.FromSeconds(50)
            };
            return client;
        }

        private sealed class MicrophoneOption
        {
            public MicrophoneOption(int id, string name, string hostApi, bool isDefault)
            {
                Id = id;
                Name = name;
                HostApi = hostApi;
                IsDefault = isDefault;
            }

            public int Id { get; private set; }
            public string Name { get; private set; }
            public string HostApi { get; private set; }
            public bool IsDefault { get; private set; }
        }

        private sealed class PendingAction
        {
            public PendingAction(string token, string label, string detail, string risk)
            {
                Token = token;
                Label = label;
                Detail = detail;
                Risk = risk;
            }

            public string Token { get; private set; }
            public string Label { get; private set; }
            public string Detail { get; private set; }
            public string Risk { get; private set; }
        }

        private sealed class ApiException : Exception
        {
            public ApiException(string message)
                : base(message)
            {
            }
        }
    }

    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            var application = new Application
            {
                ShutdownMode = ShutdownMode.OnMainWindowClose
            };
            application.Run(new JarvisPetWindow());
        }
    }
}
