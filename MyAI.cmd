<# :: Hybrid CMD / Powershell Loader - Rename to .CMD or .PS1
@START /MIN "Loader..." POWERSHELL -nop -c "iex ([io.file]::ReadAllText('%~f0'))">nul&EXIT
#>

[bool]$ClientServerHybrid = $true # <--- Set $false for Client Only Mode
[string]$ServerAddress = "127.0.0.1" # <--- [Client Only option] Server titlebar will show IP addresses you can enter here when running, hostnames can also be used e.g. myAImodel.com
[int]$ServerPort = 8000 # <--- This needs to be the same for both server and client, Server titlebar will show port when running

if($ClientServerHybrid) {
	[bool]$localOnly = $false # <--- Set $false for [Client Only] <==> [Server] network connectivity
	[string]$Model = $null # <--- Override autoload by replacing $null with a value for $Model - Default demo models are set to Llama variants
	[string]$default_Model_8GB = "unsloth/Llama-3.2-3B-Instruct"
	[string]$default_Model_12GBplus = "unsloth/Meta-Llama-3.1-8B-Instruct"
	[int]$contextLength = 28672
	[double]$maxVRAM = 0.87
	[int]$MaxTokens = 1000
	[double]$Temperature = 0.3
	[bool]$quantization = $true
	[bool]$forceFreshModelDownload = $false # <--- Set this to $true if you need to refresh the selected model (If you interrupt the initial download you need to do this to finish it, otherwise the script will try to load the partial files and crash, if you start altering models and get undesired results you can use this to go back to baseline easily) - Otherwise if set $false a cached model will be used.
	[string]$rootPassword = "pass" # <--- Change this
	[int]$requiredVRAMGB = 8 # <--- Minimum System Requirements - Nvidia GPU
}

if ($ClientServerHybrid) { $ServerAddress = "localhost" }
[string]$ServerUrl = "http://${ServerAddress}:$ServerPort/v1/chat/completions"

# Hide Console Window
Add-Type -MemberDefinition @"
[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr handle, int nCmdShow);
"@ -Name "Win32" -Namespace "Win32Functions"
$hwnd = [Win32Functions.Win32]::GetConsoleWindow()
if ($hwnd -ne [IntPtr]::Zero) {
	[void][Win32Functions.Win32]::ShowWindow($hwnd, 0)
} else {
	$currentProcessId = $PID
	$terminalProcess = $null
	while ($currentProcessId) {
		$currentProcess = Get-Process -Id $currentProcessId -ErrorAction SilentlyContinue
		if ($currentProcess.ProcessName -eq 'WindowsTerminal') {
			$terminalProcess = $currentProcess
			break
		}
		$currentProcessId = (Get-CimInstance Win32_Process -Filter "ProcessId = $currentProcessId" -ErrorAction SilentlyContinue).ParentProcessId
	}
	if ($terminalProcess) {
		$hwnd = $terminalProcess.MainWindowHandle
		if ($hwnd -ne [IntPtr]::Zero) {
			[void][Win32Functions.Win32]::ShowWindow($hwnd, 0)
		}
	}
}

$AppId = 'MyAI'
$oneInstance = $false
$script:SingleInstanceEvent = New-Object Threading.EventWaitHandle $true,([Threading.EventResetMode]::ManualReset),"Global\$AppId",([ref] $oneInstance)
if (-not $oneInstance) {
	$alreadyRunning = New-Object -ComObject Wscript.Shell
	$alreadyRunning.Popup("$AppId is already running!", 0, 'ERROR:', 0x0) | Out-Null
	Exit
}

# Verify Administrator, Detect GPU(s)/VRAM, and set FlashInfer support Enabled/Disabled
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
	Write-Host "This script requires administrative privileges."
	Write-Host "Press enter to exit . . ."
	$null = Read-Host
	exit
}
$flashInferSupportedGpus = @(
	'RTX 30[0-9]{2}', # Ampere: RTX 3090, 3080, 3070, 3060, etc.
	'RTX 40[0-9]{2}', # Ada Lovelace: RTX 4000, 4080, 4090, 4070, etc.
	'RTX 50[0-9]{2}', # Blackwell: RTX 5090, 5080, 5070, etc.
	'RTX 60[0-9]{2}', # Blackwell: RTX 6000, future cards
	'RTX PRO 60[0-9]{2}', # Blackwell: RTX PRO 6000 96GB, future cards
	'A100', 'A30', 'A40', 'H100', 'L40', 'L4' # Server GPUs, no one is using these on a Windows based machine, but just in case ;P
)
$gpuPattern = ($flashInferSupportedGpus -join '|')
try {
	$nvidiaSmiOutput = & nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader,nounits
	if (-not $nvidiaSmiOutput) {
		$endScriptGPU = New-Object -ComObject WScript.Shell
		$endScriptGPU.Popup("[nvidia-smi] returned no GPU data.`n`nEnsure NVIDIA drivers are installed.", 0, "nVidia GPU not found:", 0 + 16 + 4096)
		exit
	}
	# GPU list for dropdown, track highest VRAM
	$script:gpuList = @()
	$maxVramGB = 0
	$defaultGpuIndex = -1
	$script:useFlashInfer = $false
	foreach ($line in $nvidiaSmiOutput) {
		$gpuData = $line -split ',\s*'
		$gpuIndex = [int]$gpuData[0]
		$cleanGpuName = $gpuData[1] -replace '^NVIDIA\s+', '' -replace '\s+[0-9]+GB.*$', ''
		$gpuMemoryMB = [int]$gpuData[2]
		$gpuVramGB = [math]::Round($gpuMemoryMB / 1024, 0)
		$script:gpuList += [PSCustomObject]@{
			Index = $gpuIndex
			Name = $cleanGpuName
			VramGB = $gpuVramGB
			DisplayName = "$cleanGpuName ($gpuVramGB GB)"
		}
		if ($gpuVramGB -gt $maxVramGB) {
			$maxVramGB = $gpuVramGB
			$defaultGpuIndex = $gpuIndex
			$script:useFlashInfer = $cleanGpuName -match $gpuPattern
		}
	}
	# Default to highest-VRAM GPU
	$script:selectedGpuIndex = $defaultGpuIndex
	$selectedGpu = $script:gpuList | Where-Object { $_.Index -eq $defaultGpuIndex }
	if ($maxVramGB -lt $requiredVRAMGB) {
		$endScriptVRAM = New-Object -ComObject WScript.Shell
		$endScriptVRAM.Popup("This system does not have enough VRAM.`n`nAt least $requiredVRAMGB GB VRAM is required.", 0, "ERROR:", 0 + 16 + 4096)
		exit
	}
	if (-not $Model) {
		$Model = if ($maxVramGB -ge 12) { $default_Model_12GBplus } else { $default_Model_8GB }
		$ModelText = $Model
	} else {
		$ModelText = $Model		
	}
} catch {
	$endScriptGPU = New-Object -ComObject WScript.Shell
	$endScriptGPU.Popup("[nvidia-smi] failed: $_`n`nEnsure NVIDIA drivers are installed.", 0, "nVidia Error:", 0 + 16 + 4096)
	exit
}

function rebootRequired() {
	$rebootYN = New-Object -ComObject WScript.Shell
	$rebootResult = $rebootYN.Popup("A reboot is required to continue the installation.`n`nPlease save your work before proceeding.`n`nWould you like to reboot now?", 0, "Reboot Required", 4 + 48 + 4096)
	if ($rebootResult -eq 6) {
		shutdown /r /t 0
	} else {
		exit
	}
}

if ($ClientServerHybrid) {
	$wslStatus = (wsl --status)
	if ($LASTEXITCODE -ne 0) {
		$wslEnableYN = New-Object -ComObject WScript.Shell
		$wslResult = $wslEnableYN.Popup("Windows Subsystem for Linux needs to be enabled on this system to continue`n`nWould you like to enable it?", 0, "WSL Not Installed", 4 + 48 + 4096)
		if ($wslResult -eq 6) {
		Start-Process -FilePath "powershell.exe" -ArgumentList '-NoProfile -Command "Write-Host ''Enabling Windows Subsystem for Linux v2 and HyperVPlatform...Please Wait (This may take a few minutes)''; Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All -NoRestart | Out-Null; Write-Host ''HyperVisorPlatform enabled for NAT''; & wsl --install --no-distribution"' -Wait
			rebootRequired
		} else {
			exit
		}
	}
	$wslStatus = $wslStatus -replace "\0", ""
	if ($wslStatus -like "*WSL2*") {
		rebootRequired
	}
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

# Animate Background w/C# - If something is taking a while and you're worried if the script is frozen, a moving background is a good sign, a frozen one is not ;P ..Be patient..
try {
	Add-Type -TypeDefinition @'
using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using System.Collections.Generic;

namespace MyAI.Visuals
{
	public class Starfield : FrameworkElement
	{
		private List<Star> stars = new List<Star>();
		private Random rand = new Random();
		private double globalTime = 0;
		private double blinkSpeed = 0.05;
		private double colorSpeed = 0.03;
		private double pulseFrequency = 0.05;
		private double pulseAmplitude = 0.1;
		private double particleOpacity = 1.0;
		public DispatcherTimer timer;

		public class Star
		{
			public double PosX { get; set; }
			public double PosY { get; set; }
			public double DirX { get; set; }
			public double DirY { get; set; }
			public double Speed { get; set; }
			public double Size { get; set; }
			public double BlinkPhase { get; set; }
			public double BlinkAmplitude { get; set; }
			public double CurveFactor { get; set; }
			public double ColorPhase { get; set; }
		}

		public Starfield()
		{
			int numStars = 225;
			for (int i = 0; i < numStars; i++)
			{
				double dirX = rand.NextDouble() * 2 - 1;
				double dirY = rand.NextDouble() * 2 - 1;
				double norm = Math.Sqrt(dirX * dirX + dirY * dirY);
				if (norm > 0)
				{
					dirX /= norm;
					dirY /= norm;
				}

				stars.Add(new Star
				{
					PosX = rand.NextDouble() * this.ActualWidth,
					PosY = rand.NextDouble() * this.ActualHeight,
					DirX = dirX,
					DirY = dirY,
					Speed = rand.NextDouble() * 0.5 + 0.1,
					Size = rand.NextDouble() * 5.5 + 0.5,
					BlinkPhase = rand.NextDouble() * Math.PI * 2,
					BlinkAmplitude = rand.NextDouble() * 0.3 + 0.2,
					CurveFactor = (rand.NextDouble() - 0.5) * 0.05,
					ColorPhase = rand.NextDouble() * Math.PI * 2
				});
			}

			timer = new DispatcherTimer();
			timer.Interval = TimeSpan.FromMilliseconds(16);
			timer.Tick += Timer_Tick;
			timer.Start();
		}

		private void Timer_Tick(object sender, EventArgs e)
		{
			globalTime += timer.Interval.TotalSeconds;

			if (ActualWidth <= 0 || ActualHeight <= 0)
			{
				return;
			}

			foreach (var star in stars)
			{
				star.DirX += star.CurveFactor * 0.01;
				star.DirY += star.CurveFactor * 0.01;
				double norm = Math.Sqrt(star.DirX * star.DirX + star.DirY * star.DirY);
				if (norm > 0)
				{
					star.DirX /= norm;
					star.DirY /= norm;
				}

				double moveDist = star.Speed;
				star.PosX += star.DirX * moveDist;
				star.PosY += star.DirY * moveDist;

				if (star.PosX < 0) star.PosX += this.ActualWidth;
				if (star.PosX > this.ActualWidth) star.PosX -= this.ActualWidth;
				if (star.PosY < 0) star.PosY += this.ActualHeight;
				if (star.PosY > this.ActualHeight) star.PosY -= this.ActualHeight;
			}

			this.InvalidateVisual();
		}

		protected override void OnRender(DrawingContext drawingContext)
		{
			double pulse = 1 + pulseAmplitude * Math.Sin(globalTime * pulseFrequency * 2 * Math.PI);

			Color sColor1 = Color.FromRgb(100, 149, 237); // Cornflower Blue
			Color sColor2 = Color.FromRgb(147, 112, 219); // Medium Purple

			foreach (var star in stars)
			{
				double blink = 0.3 + star.BlinkAmplitude * (Math.Sin(globalTime * blinkSpeed + star.BlinkPhase) + 1) / 2;
				byte alpha = (byte)(Math.Min(255, 255 * blink * particleOpacity));

				double colorFactor = (Math.Sin(globalTime * colorSpeed + star.ColorPhase) + 1) / 2;
				byte r = (byte)(sColor1.R * (1 - colorFactor) + sColor2.R * colorFactor);
				byte g = (byte)(sColor1.G * (1 - colorFactor) + sColor2.G * colorFactor);
				byte b = (byte)(sColor1.B * (1 - colorFactor) + sColor2.B * colorFactor);

				Color color = Color.FromArgb(alpha, r, g, b);

				SolidColorBrush brush = new SolidColorBrush(color);
				drawingContext.DrawEllipse(brush, null, new Point(star.PosX, star.PosY), star.Size / 2 * pulse, star.Size / 2 * pulse);
			}
		}

		protected override void OnRenderSizeChanged(SizeChangedInfo sizeInfo)
		{
			base.OnRenderSizeChanged(sizeInfo);
			foreach (var star in stars)
			{
				star.PosX = rand.NextDouble() * this.ActualWidth;
				star.PosY = rand.NextDouble() * this.ActualHeight;

				star.DirX = rand.NextDouble() * 2 - 1;
				star.DirY = rand.NextDouble() * 2 - 1;
				double norm = Math.Sqrt(star.DirX * star.DirX + star.DirY * star.DirY);
				if (norm > 0)
				{
					star.DirX /= norm;
					star.DirY /= norm;
				}
			}
		}
	}
}
'@ -ReferencedAssemblies PresentationFramework,WindowsBase,System.Xaml,PresentationCore -ErrorAction Stop
} catch {
	[System.Windows.MessageBox]::Show("Error compiling Starfield: $_", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
	exit
}

# Get icons from DLL or EXE files via shell32.dll (for use with Titlebar, taskbar, systray)
$getIcons = @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using System.Windows;

namespace System
{
	public class IconExtractor
	{
		public static Icon Extract(string file, int number, bool largeIcon)
		{
			IntPtr large;
			IntPtr small;
			ExtractIconEx(file, number, out large, out small, 1);
			try
			{
				return Icon.FromHandle(largeIcon ? large : small);
			}
			catch
			{
				return null;
			}
		}
		public static BitmapSource IconToBitmapSource(Icon icon)
		{
			return Imaging.CreateBitmapSourceFromHIcon(
				icon.Handle,
				Int32Rect.Empty,
				BitmapSizeOptions.FromEmptyOptions());
		}
		[DllImport("Shell32.dll", EntryPoint = "ExtractIconExW", CharSet = CharSet.Unicode, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
		private static extern int ExtractIconEx(string sFile, int iIndex, out IntPtr piLargeVersion, out IntPtr piSmallVersion, int amountIcons);
	}
}
"@
Add-Type -TypeDefinition $getIcons -ReferencedAssemblies System.Windows.Forms, System.Drawing, PresentationCore, PresentationFramework, WindowsBase

# Main UI
$xaml = @'
<Window
	xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
	xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
	Title="MyAI vLLM Model Launcher" Height="600" Width="800"
	WindowStartupLocation="CenterScreen"
	WindowStyle="None"
	AllowsTransparency="True"
	Background="Transparent">
	<Window.Resources>
		<Style x:Key="NoMouseOverButton" TargetType="Button">
			<Setter Property="Background" Value="#333333"/>
			<Setter Property="BorderThickness" Value="0"/>
			<Setter Property="Template">
				<Setter.Value>
					<ControlTemplate TargetType="Button">
						<Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="0">
							<ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
						</Border>
						<ControlTemplate.Triggers>
							<Trigger Property="IsMouseOver" Value="True">
								<Setter TargetName="ButtonBorder" Property="Background" Value="{Binding RelativeSource={RelativeSource TemplatedParent}, Path=Tag}"/>
								<Setter Property="Foreground" Value="#FFFFFF"/>
							</Trigger>
						</ControlTemplate.Triggers>
					</ControlTemplate>
				</Setter.Value>
			</Setter>
		</Style>
		<Style x:Key="CloseButtonStyle" TargetType="Button">
			<Setter Property="Background" Value="#333333"/>
			<Setter Property="BorderThickness" Value="0"/>
			<Setter Property="Template">
				<Setter.Value>
					<ControlTemplate TargetType="Button">
						<Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="0,10,0,0">
							<ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
						</Border>
						<ControlTemplate.Triggers>
							<Trigger Property="IsMouseOver" Value="True">
								<Setter TargetName="ButtonBorder" Property="Background" Value="{Binding RelativeSource={RelativeSource TemplatedParent}, Path=Tag}"/>
								<Setter Property="Foreground" Value="#FFFFFF"/>
							</Trigger>
						</ControlTemplate.Triggers>
					</ControlTemplate>
				</Setter.Value>
			</Setter>
		</Style>
		<Style x:Key="NoMouseOverToggleButtonStyle" TargetType="ToggleButton">
			<Setter Property="Background" Value="#333333"/>
			<Setter Property="BorderThickness" Value="0"/>
			<Setter Property="Template">
				<Setter.Value>
					<ControlTemplate TargetType="ToggleButton">
						<Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="0,5,5,0">
							<ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
						</Border>
						<ControlTemplate.Triggers>
							<Trigger Property="IsMouseOver" Value="True">
								<Setter TargetName="ButtonBorder" Property="Background" Value="#2A2A2A"/>
							</Trigger>
							<Trigger Property="IsChecked" Value="True">
								<Setter TargetName="ButtonBorder" Property="BorderBrush" Value="#6495ED"/>
							</Trigger>
						</ControlTemplate.Triggers>
					</ControlTemplate>
				</Setter.Value>
			</Setter>
		</Style>
		<Style x:Key="NoMouseOverComboBoxStyle" TargetType="{x:Type ComboBox}">
			<Setter Property="Background" Value="#333333"/>
			<Setter Property="Foreground" Value="#E0E0E0"/>
			<Setter Property="BorderBrush" Value="#4A4A4A"/>
			<Setter Property="BorderThickness" Value="1"/>
			<Setter Property="FontFamily" Value="Consolas"/>
			<Setter Property="FontSize" Value="14"/>
			<Setter Property="Padding" Value="5"/>
			<Setter Property="Template">
				<Setter.Value>
					<ControlTemplate TargetType="{x:Type ComboBox}">
						<Border x:Name="OuterBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
							<Grid>
								<Grid.ColumnDefinitions>
									<ColumnDefinition Width="*" />
									<ColumnDefinition Width="Auto" />
								</Grid.ColumnDefinitions>
								<ContentPresenter x:Name="ContentSite" Grid.Column="0" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}" Margin="{TemplateBinding Padding}" VerticalAlignment="Center" HorizontalAlignment="Left" />
								<ToggleButton x:Name="ToggleButton" Grid.Column="1" Style="{StaticResource NoMouseOverToggleButtonStyle}" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
									<Path x:Name="Arrow" Data="M 0 0 L 4 4 L 8 0 Z" Fill="#E0E0E0" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="5,0" />
								</ToggleButton>
								<Popup x:Name="Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
									<Grid x:Name="DropDown" SnapsToDevicePixels="True" MinWidth="{TemplateBinding ActualWidth}" MaxHeight="200">
										<Border x:Name="DropDownBorder" Background="#333333" BorderThickness="1" BorderBrush="#4A4A4A">
											<ScrollViewer Margin="4,6,4,6" SnapsToDevicePixels="True">
												<StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
											</ScrollViewer>
										</Border>
									</Grid>
								</Popup>
							</Grid>
						</Border>
						<ControlTemplate.Triggers>
							<Trigger Property="IsMouseOver" Value="True">
								<Setter TargetName="OuterBorder" Property="Background" Value="#555555"/>
							</Trigger>
							<Trigger Property="IsEnabled" Value="False">
								<Setter Property="Opacity" Value="0.6"/>
							</Trigger>
							<Trigger Property="IsDropDownOpen" Value="True">
								<Setter TargetName="OuterBorder" Property="BorderBrush" Value="#6495ED"/>
							</Trigger>
						</ControlTemplate.Triggers>
					</ControlTemplate>
				</Setter.Value>
			</Setter>
			<Setter Property="Effect">
				<Setter.Value>
					<DropShadowEffect Color="#000000" ShadowDepth="0" BlurRadius="10" Opacity="0.5"/>
				</Setter.Value>
			</Setter>
			<Setter Property="ItemContainerStyle">
				<Setter.Value>
					<Style TargetType="{x:Type ComboBoxItem}">
						<Setter Property="Background" Value="#333333"/>
						<Setter Property="Foreground" Value="#E0E0E0"/>
						<Setter Property="Padding" Value="5"/>
						<Setter Property="Template">
							<Setter.Value>
								<ControlTemplate TargetType="{x:Type ComboBoxItem}">
									<Border x:Name="ItemBorder" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
										<ContentPresenter/>
									</Border>
									<ControlTemplate.Triggers>
										<Trigger Property="IsHighlighted" Value="True">
											<Setter TargetName="ItemBorder" Property="Background" Value="#555555"/>
										</Trigger>
									</ControlTemplate.Triggers>
								</ControlTemplate>
							</Setter.Value>
						</Setter>
					</Style>
				</Setter.Value>
			</Setter>
			<Setter Property="ScrollViewer.VerticalScrollBarVisibility" Value="Auto"/>
			<Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
		</Style>
		<Style x:Key="ActionButtonStyle" TargetType="Button">
			<Setter Property="Background" Value="Transparent"/>
			<Setter Property="BorderThickness" Value="0"/>
			<Setter Property="BorderBrush" Value="#999999"/>
			<Setter Property="RenderTransform">
				<Setter.Value>
					<TranslateTransform/>
				</Setter.Value>
			</Setter>
			<Setter Property="Effect">
				<Setter.Value>
					<DropShadowEffect ShadowDepth="5" BlurRadius="5" Color="Black" Direction="270"/>
				</Setter.Value>
			</Setter>
			<Setter Property="Template">
				<Setter.Value>
					<ControlTemplate TargetType="Button">
						<Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
							<ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
						</Border>
					</ControlTemplate>
				</Setter.Value>
			</Setter>
			<Setter Property="Width" Value="60"/>
			<Setter Property="Height" Value="60"/>
			<Style.Resources>
				<Storyboard x:Key="mouseEnterAnimation">
					<DoubleAnimation Storyboard.TargetProperty="RenderTransform.(TranslateTransform.Y)" To="-3" Duration="0:0:0.2"/>
					<DoubleAnimation Storyboard.TargetProperty="Effect.ShadowDepth" To="10" Duration="0:0:0.2"/>
					<DoubleAnimation Storyboard.TargetProperty="Effect.BlurRadius" To="10" Duration="0:0:0.2"/>
				</Storyboard>
				<Storyboard x:Key="mouseLeaveAnimation">
					<DoubleAnimation Storyboard.TargetProperty="RenderTransform.(TranslateTransform.Y)" To="0" Duration="0:0:0.2"/>
					<DoubleAnimation Storyboard.TargetProperty="Effect.ShadowDepth" To="5" Duration="0:0:0.2"/>
					<DoubleAnimation Storyboard.TargetProperty="Effect.BlurRadius" To="5" Duration="0:0:0.2"/>
				</Storyboard>
			</Style.Resources>
			<Style.Triggers>
				<Trigger Property="IsMouseOver" Value="True">
					<Trigger.EnterActions>
						<BeginStoryboard Storyboard="{StaticResource mouseEnterAnimation}"/>
					</Trigger.EnterActions>
					<Trigger.ExitActions>
						<BeginStoryboard Storyboard="{StaticResource mouseLeaveAnimation}"/>
					</Trigger.ExitActions>
				</Trigger>
			</Style.Triggers>
		</Style>
		<Style x:Key="RTFScrollBarStyle" TargetType="{x:Type ScrollBar}">
			<Setter Property="Background" Value="#333333"/>
			<Setter Property="BorderBrush" Value="#333333"/>
			<Setter Property="BorderThickness" Value="0"/>
			<Setter Property="Template">
				<Setter.Value>
					<ControlTemplate TargetType="{x:Type ScrollBar}">
						<Grid x:Name="Bg" SnapsToDevicePixels="true" Background="#333333">
							<Track x:Name="PART_Track" IsDirectionReversed="true" IsEnabled="{TemplateBinding IsEnabled}">
								<Track.Thumb>
									<Thumb>
										<Thumb.Template>
											<ControlTemplate TargetType="{x:Type Thumb}">
												<Border x:Name="thumb" Background="#6495ED" BorderBrush="#6495ED" BorderThickness="1" CornerRadius="4"/>
											</ControlTemplate>
										</Thumb.Template>
									</Thumb>
								</Track.Thumb>
							</Track>
						</Grid>
					</ControlTemplate>
				</Setter.Value>
			</Setter>
		</Style>
		<Style x:Key="SendButtonStyle" TargetType="Button">
			<Setter Property="Background" Value="#2D2D2D"/>
			<Setter Property="BorderBrush" Value="#4A4A4A"/>
			<Setter Property="BorderThickness" Value="1"/>
			<Setter Property="ToolTip" Value="..Send.."/>
			<Setter Property="Effect">
				<Setter.Value>
					<DropShadowEffect Color="#000000" ShadowDepth="0" BlurRadius="3" Opacity="0.5"/>
				</Setter.Value>
			</Setter>
			<Setter Property="Template">
				<Setter.Value>
					<ControlTemplate TargetType="Button">
						<Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
							<ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
						</Border>
						<ControlTemplate.Triggers>
							<DataTrigger Binding="{Binding IsMouseOver, ElementName=SendButtonOverlay}" Value="True">
								<DataTrigger.EnterActions>
									<BeginStoryboard>
										<Storyboard>
											<ColorAnimation Storyboard.TargetName="ButtonBorder" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="#4A4A4A" Duration="0:0:0.2"/>
											<ColorAnimation Storyboard.TargetName="ButtonBorder" Storyboard.TargetProperty="(Border.BorderBrush).(SolidColorBrush.Color)" From="#4A4A4A" To="#6495ED" Duration="0:0:0.5" AutoReverse="True" RepeatBehavior="Forever"/>
										</Storyboard>
									</BeginStoryboard>
								</DataTrigger.EnterActions>
								<DataTrigger.ExitActions>
									<BeginStoryboard>
										<Storyboard>
											<ColorAnimation Storyboard.TargetName="ButtonBorder" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="#2D2D2D" Duration="0:0:0.2"/>
											<ColorAnimation Storyboard.TargetName="ButtonBorder" Storyboard.TargetProperty="(Border.BorderBrush).(SolidColorBrush.Color)" To="#4A4A4A" Duration="0:0:0.2"/>
										</Storyboard>
									</BeginStoryboard>
								</DataTrigger.ExitActions>
							</DataTrigger>
						</ControlTemplate.Triggers>
					</ControlTemplate>
				</Setter.Value>
			</Setter>
		</Style>
		<Style x:Key="SendButtonOverlayStyle" TargetType="Button">
			<Setter Property="Background" Value="Transparent"/>
			<Setter Property="BorderBrush" Value="Transparent"/>
			<Setter Property="BorderThickness" Value="0"/>
			<Setter Property="Effect">
				<Setter.Value>
					<DropShadowEffect Color="#000000" ShadowDepth="0" BlurRadius="3" Opacity="0.7"/>
				</Setter.Value>
			</Setter>
			<Setter Property="RenderTransform">
				<Setter.Value>
					<TranslateTransform Y="0"/>
				</Setter.Value>
			</Setter>
			<Setter Property="Template">
				<Setter.Value>
					<ControlTemplate TargetType="Button">
						<Border x:Name="OverlayBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
							<ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
						</Border>
					</ControlTemplate>
				</Setter.Value>
			</Setter>
			<Setter Property="Width" Value="99"/>
			<Setter Property="Height" Value="60"/>
			<Style.Resources>
				<Storyboard x:Key="mouseEnterAnimation">
					<DoubleAnimation Storyboard.TargetProperty="Effect.BlurRadius" To="10" Duration="0:0:0.2"/>
					<DoubleAnimation Storyboard.TargetProperty="(RenderTransform).(ScaleTransform.ScaleX)" To="0.9" Duration="0:0:0.2"/>
					<DoubleAnimation Storyboard.TargetProperty="(RenderTransform).(ScaleTransform.ScaleY)" To="0.9" Duration="0:0:0.2"/>
				</Storyboard>
				<Storyboard x:Key="mouseLeaveAnimation">
					<DoubleAnimation Storyboard.TargetProperty="Effect.BlurRadius" To="3" Duration="0:0:0.2"/>
					<DoubleAnimation Storyboard.TargetProperty="(RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.2"/>
					<DoubleAnimation Storyboard.TargetProperty="(RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.2"/>
				</Storyboard>
			</Style.Resources>
			<Style.Triggers>
				<Trigger Property="IsMouseOver" Value="True">
					<Trigger.EnterActions>
						<BeginStoryboard Storyboard="{StaticResource mouseEnterAnimation}"/>
					</Trigger.EnterActions>
					<Trigger.ExitActions>
						<BeginStoryboard Storyboard="{StaticResource mouseLeaveAnimation}"/>
					</Trigger.ExitActions>
				</Trigger>
			</Style.Triggers>
		</Style>
		<Style x:Key="TextBoxStyle" TargetType="{x:Type TextBox}">
			<Setter Property="Background" Value="#252525"/>
			<Setter Property="Foreground" Value="#E0E0E0"/>
			<Setter Property="BorderBrush" Value="#4A4A4A"/>
			<Setter Property="BorderThickness" Value="1"/>
			<Setter Property="Template">
				<Setter.Value>
					<ControlTemplate TargetType="{x:Type TextBox}">
						<Border x:Name="TextBoxBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
							<ScrollViewer x:Name="PART_ContentHost"/>
						</Border>
						<ControlTemplate.Triggers>
							<Trigger Property="IsEnabled" Value="False">
								<Setter Property="Opacity" Value="0.6"/>
							</Trigger>
						</ControlTemplate.Triggers>
					</ControlTemplate>
				</Setter.Value>
			</Setter>
			<Setter Property="Effect">
				<Setter.Value>
					<DropShadowEffect Color="#000000" ShadowDepth="0" BlurRadius="10" Opacity="0.5"/>
				</Setter.Value>
			</Setter>
		</Style>
		<Style x:Key="RichTextBoxStyle" TargetType="{x:Type RichTextBox}">
			<Setter Property="Background" Value="#252525"/>
			<Setter Property="Foreground" Value="#E0E0E0"/>
			<Setter Property="BorderBrush" Value="#4A4A4A"/>
			<Setter Property="BorderThickness" Value="1"/>
			<Setter Property="Template">
				<Setter.Value>
					<ControlTemplate TargetType="{x:Type RichTextBox}">
						<Border x:Name="RichTextBoxBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
							<ScrollViewer x:Name="PART_ContentHost"/>
						</Border>
						<ControlTemplate.Triggers>
							<Trigger Property="IsEnabled" Value="False">
								<Setter Property="Opacity" Value="0.6"/>
							</Trigger>
						</ControlTemplate.Triggers>
					</ControlTemplate>
				</Setter.Value>
			</Setter>
			<Setter Property="Effect">
				<Setter.Value>
					<DropShadowEffect Color="#000000" ShadowDepth="0" BlurRadius="10" Opacity="0.5"/>
				</Setter.Value>
			</Setter>
		</Style>
	</Window.Resources>
	<Border BorderBrush="#777777" BorderThickness="1" CornerRadius="10" Background="#1E1E1E">
		<Grid x:Name="MainGrid">
			<Grid.RowDefinitions>
				<RowDefinition Height="30"/>
				<RowDefinition Height="*"/>
			</Grid.RowDefinitions>
			<Border Grid.Row="0" BorderBrush="#777777" BorderThickness="1,1,1,0" CornerRadius="10,10,0,0" Background="#333333">
				<Canvas>
					<Image x:Name="WindowIconImage" Height="16" Width="16" Canvas.Left="10" Canvas.Top="7"/>
					<TextBlock x:Name="WindowTitleText" Text="MyAI vLLM Model Launcher" Foreground="#EEEEEE" FontSize="12" FontWeight="Bold" Canvas.Left="30" Canvas.Top="7"/>
					<Button x:Name="btnMinimize" Width="30" Height="28" Canvas.Right="30" Style="{StaticResource NoMouseOverButton}" Tag="#666666">
						<TextBlock Text="-" Foreground="#EEEEEE" FontWeight="Bold" FontSize="16" VerticalAlignment="Center" HorizontalAlignment="Center"/>
					</Button>
					<Border x:Name="btnClose" Width="30" Height="28" Canvas.Right="0" Background="#333333" BorderThickness="0" CornerRadius="0,10,0,0">
						<Button x:Name="btnCloseInner" Style="{StaticResource CloseButtonStyle}" Tag="#FF0000">
							<TextBlock Text="X" Foreground="#EEEEEE" FontWeight="Bold" FontSize="12" VerticalAlignment="Center" HorizontalAlignment="Center"/>
						</Button>
					</Border>
				</Canvas>
			</Border>
			<Grid x:Name="ContentGrid" Grid.Row="1" Margin="10" ClipToBounds="False">
				<StackPanel x:Name="WaitPanel" VerticalAlignment="Center" HorizontalAlignment="Center" Panel.ZIndex="1">
					<TextBlock x:Name="WaitText" Text="...Please Wait..." HorizontalAlignment="Center" FontSize="16" Foreground="#E0E0E0"/>
				</StackPanel>
				<Border x:Name="BackgroundBorder" CornerRadius="5" Background="#2D2D2D" Opacity="0.7" HorizontalAlignment="Center" VerticalAlignment="Center" Panel.ZIndex="0">
					<Border.Style>
						<Style TargetType="Border">
							<Style.Triggers>
								<DataTrigger Binding="{Binding Visibility, ElementName=ClientPanelBorder}" Value="Visible">
									<Setter Property="Width" Value="NaN"/>
									<Setter Property="Height" Value="NaN"/>
									<Setter Property="HorizontalAlignment" Value="Stretch"/>
									<Setter Property="VerticalAlignment" Value="Stretch"/>
								</DataTrigger>
								<DataTrigger Binding="{Binding Visibility, ElementName=ClientPanelBorder}" Value="Collapsed">
									<Setter Property="Width" Value="350"/>
									<Setter Property="Height" Value="220"/>
									<Setter Property="HorizontalAlignment" Value="Center"/>
									<Setter Property="VerticalAlignment" Value="Center"/>
								</DataTrigger>
							</Style.Triggers>
						</Style>
					</Border.Style>
					<Border.Effect>
						<DropShadowEffect Color="#000000" ShadowDepth="0" BlurRadius="10" Opacity="0.5"/>
					</Border.Effect>
				</Border>
				<Border x:Name="ClientPanelBorder" CornerRadius="5" Background="#2D2D2D" Opacity="0.7" Margin="0" Panel.ZIndex="2" Visibility="Collapsed">
					<Border.Effect>
						<DropShadowEffect Color="#000000" ShadowDepth="0" BlurRadius="10" Opacity="0.5"/>
					</Border.Effect>
					<TabControl x:Name="ClientTabControl" Margin="0" Background="#2D2D2D" BorderThickness="0">
						<TabControl.Resources>
							<Style x:Key="NoMouseOverTabItemStyle" TargetType="{x:Type TabItem}">
								<Setter Property="Background" Value="#333333"/>
								<Setter Property="Foreground" Value="#E0E0E0"/>
								<Setter Property="BorderBrush" Value="#4A4A4A"/>
								<Setter Property="BorderThickness" Value="1"/>
								<Setter Property="Padding" Value="10,5"/>
								<Setter Property="MinWidth" Value="150"/>
								<Setter Property="Template">
									<Setter.Value>
										<ControlTemplate TargetType="{x:Type TabItem}">
											<Border x:Name="TabBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5,5,0,0" Margin="2,0">
												<ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
											</Border>
											<ControlTemplate.Triggers>
												<Trigger Property="IsSelected" Value="True">
													<Setter TargetName="TabBorder" Property="Background" Value="#6495ED"/>
													<Setter Property="Foreground" Value="#FFFFFF"/>
												</Trigger>
											</ControlTemplate.Triggers>
										</ControlTemplate>
									</Setter.Value>
								</Setter>
							</Style>
						</TabControl.Resources>
						<TabItem Header="Client" Name="ClientTab" Style="{StaticResource NoMouseOverTabItemStyle}">
							<Grid x:Name="ClientPanel">
								<Grid.RowDefinitions>
									<RowDefinition Height="*"/>
									<RowDefinition Height="Auto"/>
								</Grid.RowDefinitions>
								<RichTextBox x:Name="OutputTextBox" Grid.Row="0" Margin="10" IsReadOnly="True" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="14" Style="{StaticResource RichTextBoxStyle}">
									<RichTextBox.Resources>
										<Style TargetType="{x:Type ScrollBar}" BasedOn="{StaticResource RTFScrollBarStyle}"/>
									</RichTextBox.Resources>
								</RichTextBox>
								<StackPanel Grid.Row="1" Orientation="Horizontal" Margin="10,10,10,10">
									<TextBox x:Name="InputTextBox" Width="649" Height="60" Margin="0,0,10,0" VerticalContentAlignment="Top" AcceptsReturn="True" AcceptsTab="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap" Style="{StaticResource TextBoxStyle}">
										<TextBox.Resources>
											<Style TargetType="{x:Type ScrollBar}" BasedOn="{StaticResource RTFScrollBarStyle}"/>
										</TextBox.Resources>
									</TextBox>
									<Grid Width="99" Height="60" HorizontalAlignment="Right">
										<Button x:Name="SendButton" Width="90" Height="60" Style="{StaticResource SendButtonStyle}"/>
										<Button x:Name="SendButtonOverlay" Style="{StaticResource SendButtonOverlayStyle}">
											<Path Fill="#FFFFFF" Data="M8,7.71L18,12L8,16.29V12.95L15.14,12L8,11.05V7.71M12,2A10,10 0 0,1 22,12A10,10 0 0,1 12,22A10,10 0 0,1 2,12A10,10 0 0,1 12,2M12,4A8,8 0 0,0 4,12A8,8 0 0,0 12,20A8,8 0 0,0 20,12A8,8 0 0,0 12,4Z" Stretch="Uniform" Margin="10"/>
										</Button>
									</Grid>
								</StackPanel>
							</Grid>
						</TabItem>
						<TabItem Header="Server" Name="ServerTab" Style="{StaticResource NoMouseOverTabItemStyle}">
							<RichTextBox x:Name="ServerTextBox" Margin="10" IsReadOnly="True" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="14" Style="{StaticResource RichTextBoxStyle}">
								<RichTextBox.Resources>
									<Style TargetType="{x:Type ScrollBar}" BasedOn="{StaticResource RTFScrollBarStyle}"/>
								</RichTextBox.Resources>
								<FlowDocument>
									<Paragraph>
										<Run Text="Server output will appear here." Foreground="#E0E0E0"/>
									</Paragraph>
								</FlowDocument>
							</RichTextBox>
						</TabItem>
					</TabControl>
				</Border>
				<StackPanel x:Name="InstallPanel" VerticalAlignment="Center" HorizontalAlignment="Center" Visibility="Collapsed" Panel.ZIndex="1">
					<Button x:Name="InstallButton" Style="{StaticResource ActionButtonStyle}" Margin="0,-5,0,10">
						<Viewbox Width="40" Height="40">
							<Path>
								<Path.Fill>
									<LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
										<GradientStop Color="#FFFFFF" Offset="0"/>
										<GradientStop Color="#CCCCCC" Offset="0.5"/>
										<GradientStop Color="#666666" Offset="1"/>
									</LinearGradientBrush>
								</Path.Fill>
								<Path.Data>
									M8 17V15H16V17H8M16 10L12 14L8 10H10.5V6H13.5V10H16M12 2C17.5 2 22 6.5 22 12C22 17.5 17.5 22 12 22C6.5 22 2 17.5 2 12C2 6.5 6.5 2 12 2M12 4C7.58 4 4 7.58 4 12C4 16.42 7.58 20 12 20C16.42 20 20 16.42 20 12C20 7.58 16.42 4 12 4Z
								</Path.Data>
							</Path>
						</Viewbox>
					</Button>
					<TextBlock x:Name="InstallStatusText" Text="Install" HorizontalAlignment="Center" Foreground="#E0E0E0" Margin="0,10,0,0"/>
				</StackPanel>
				<StackPanel x:Name="LaunchPanel" VerticalAlignment="Center" HorizontalAlignment="Center" Visibility="Collapsed" Panel.ZIndex="1">
					<Button x:Name="LaunchButton" Style="{StaticResource ActionButtonStyle}" Margin="-6,-5,0,5">
						<Viewbox Width="40" Height="40">
							<Path>
								<Path.Fill>
									<LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
										<GradientStop Color="#FFFFFF" Offset="0"/>
										<GradientStop Color="#CCCCCC" Offset="0.5"/>
										<GradientStop Color="#666666" Offset="1"/>
									</LinearGradientBrush>
								</Path.Fill>
								<Path.Data>
									M16.56,5.44L15.11,6.89C16.84,7.94 18,9.83 18,12A6,6 0 0,1 12,18A6,6 0 0,1 6,12C6,9.83 7.16,7.94 8.88,6.88L7.44,5.44C5.36,6.88 4,9.28 4,12A8,8 0 0,0 12,20A8,8 0 0,0 20,12C20,9.28 18.64,6.88 16.56,5.44M13,3H11V13H13
								</Path.Data>
							</Path>
						</Viewbox>
					</Button>
					<TextBlock x:Name="StatusText" Text="Ready to launch model" HorizontalAlignment="Center" Foreground="#E0E0E0" Margin="0,10,0,0"/>
					<TextBlock x:Name="ModelNameText" Text="Selected Model" HorizontalAlignment="Center" Foreground="#E0E0E0" Margin="0,10,0,0" TextWrapping="Wrap" MaxWidth="300"/>
				</StackPanel>
				<Canvas Panel.ZIndex="1">
					<ComboBox x:Name="GpuSelector" Width="300" Height="30" Canvas.Left="239" Canvas.Top="100" ToolTip="Select GPU for vLLM" Style="{StaticResource NoMouseOverComboBoxStyle}" Visibility="Collapsed">
						<ComboBox.Resources>
							<Style TargetType="{x:Type ScrollBar}" BasedOn="{StaticResource RTFScrollBarStyle}"/>
						</ComboBox.Resources>
					</ComboBox>
				</Canvas>
			</Grid>
		</Grid>
	</Border>
	<Window.TaskbarItemInfo>
		<TaskbarItemInfo/>
	</Window.TaskbarItemInfo>
</Window>
'@

# Show UI
function Show-UI {
	param (
		[string]$Mode = "Wait",
		[string]$StatusMessage = "...Please Wait..."
	)

	$reader = (New-Object System.Xml.XmlNodeReader ([xml]$xaml))
	try {
		$window = [Windows.Markup.XamlReader]::Load($reader)
	} catch {
		[System.Windows.MessageBox]::Show("Error loading XAML: $_", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
		exit
	}

	# Add animated background
	try {
		$contentGrid = $window.FindName("ContentGrid")
		$starfield = New-Object MyAI.Visuals.Starfield
		$starfield.IsHitTestVisible = $false
		$starfield.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
		$starfield.VerticalAlignment = [System.Windows.VerticalAlignment]::Stretch
		$starfield.SetValue([System.Windows.Controls.Panel]::ZIndexProperty, -1)
		$contentGrid.Children.Insert(0, $starfield)
		$contentGrid.UpdateLayout()
		$window.UpdateLayout()
	} catch {
		[System.Windows.MessageBox]::Show("Error adding Starfield: $_", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
	}

	# Find controls
	$mainGrid = $window.FindName("MainGrid")
	$contentGrid = $window.FindName("ContentGrid")
	$waitPanel = $window.FindName("WaitPanel")
	$installPanel = $window.FindName("InstallPanel")
	$launchPanel = $window.FindName("LaunchPanel")
	$clientPanel = $window.FindName("ClientPanel")
	$clientPanelBorder = $window.FindName("ClientPanelBorder")
	$clientTabControl = $window.FindName("ClientTabControl")
	$clientTab = $window.FindName("ClientTab")
	$serverTab = $window.FindName("ServerTab")
	$waitText = $window.FindName("WaitText")
	$installButton = $window.FindName("InstallButton")
	$installStatusText = $window.FindName("InstallStatusText")
	$launchButton = $window.FindName("LaunchButton")
	$statusText = $window.FindName("StatusText")
	$modelNameText = $window.FindName("ModelNameText")
	$outputTextBox = $window.FindName("OutputTextBox")
	$serverTextBox = $window.FindName("ServerTextBox")
	$inputTextBox = $window.FindName("InputTextBox")
	$sendButton = $window.FindName("SendButton")
	$sendButtonOverlay = $window.FindName("SendButtonOverlay")
	$btnMinimize = $window.FindName("btnMinimize")
	$btnClose = $window.FindName("btnClose")
	$btnCloseInner = $window.FindName("btnCloseInner")
	$windowTitleText = $window.FindName("WindowTitleText")
	$windowIconImage = $window.FindName("WindowIconImage")
	$gpuSelector = $window.FindName("GpuSelector")
	$backgroundBorder = $window.FindName("BackgroundBorder")

	# Set initial tab visibility
	if (-not $ClientServerHybrid) {
		$serverTab.Visibility = "Collapsed"
	} else {
		$clientTab.Visibility = "Collapsed"
	}
	
	# Populate GPU dropdown
	if ($gpuList) {
		$gpuSelector.ItemsSource = $gpuList
		$gpuSelector.DisplayMemberPath = "DisplayName"
		$gpuSelector.SelectedValuePath = "Index"
		$gpuSelector.SelectedValue = $script:selectedGpuIndex
		$gpuSelector.Visibility = if ($Mode -eq "Launch") { "Visible" } else { "Collapsed" }
	} else {
		$gpuSelector.Items.Add("No GPUs detected")
		$gpuSelector.IsEnabled = $false
		$gpuSelector.Visibility = "Collapsed"
	}

	# Handle GPU selection
	$gpuSelector.Add_SelectionChanged({
		$selectedIndex = $gpuSelector.SelectedValue
		if ($selectedIndex -ne $null) {
			$script:selectedGpuIndex = $selectedIndex
			$selectedGpu = $script:gpuList | Where-Object { $_.Index -eq $selectedIndex }
			if ($selectedGpu.VramGB -lt $requiredVRAMGB) {
				$statusText.Text = "Selected GPU has insufficient VRAM ($($selectedGpu.VramGB) GB < $requiredVRAMGB GB)"
				$launchButton.IsEnabled = $false
			} else {
				$statusText.Text = "Ready to launch model"
				$launchButton.IsEnabled = $true
				$script:Model = if ($selectedGpu.VramGB -ge 12) { $Model_12GBplus } else { $Model_8GB }
			}
		}
	})
	
	$ModelNameText.Text = $ModelText
	
	# Set initial UI state
	$waitPanel.Visibility = if ($Mode -eq "Wait") { "Visible" } else { "Collapsed" }
	$installPanel.Visibility = if ($Mode -eq "Install") { "Visible" } else { "Collapsed" }
	$launchPanel.Visibility = if ($Mode -eq "Launch") { "Visible" } else { "Collapsed" }
	$clientPanelBorder.Visibility = if ($Mode -eq "Client") { "Visible" } else { "Collapsed" }
	$waitText.Text = $StatusMessage
	$windowTitleText.Text = if ($Mode -eq "Client") { "MyAI vLLM Client" } else { "MyAI vLLM Launcher" }

	# Enable SendButton when input is provided
	$inputTextBox.Add_TextChanged({
		$window = [System.Windows.Window]::GetWindow($this)
		if ($window -ne $null) {
			$button = $window.FindName("SendButton")
			if ($button -ne $null) {
				$button.IsEnabled = -not [string]::IsNullOrWhiteSpace($this.Text)
			}
		}
	})

	return [PSCustomObject]@{
		Window = $window
		MainGrid = $mainGrid
		ContentGrid = $contentGrid
		WaitPanel = $waitPanel
		InstallPanel = $installPanel
		LaunchPanel = $launchPanel
		ClientPanel = $clientPanel
		ClientPanelBorder = $clientPanelBorder
		ClientTabControl = $clientTabControl
		ClientTab = $clientTab
		ServerTab = $serverTab
		InstallButton = $installButton
		InstallStatusText = $installStatusText
		LaunchButton = $launchButton
		StatusText = $statusText
		ModelNameText = $modelNameText
		OutputTextBox = $outputTextBox
		ServerTextBox = $serverTextBox
		InputTextBox = $inputTextBox
		SendButton = $sendButton
		SendButtonOverlay = $sendButtonOverlay
		BtnMinimize = $btnMinimize
		BtnClose = $btnClose
		BtnCloseInner = $btnCloseInner
		WindowTitleText = $windowTitleText
		WindowIconImage = $windowIconImage
		GpuSelector = $gpuSelector
		BackgroundBorder = $backgroundBorder
	}
}

# Function to check if vLLM server is running
function Test-VllmRunning {
	param (
		[string]$ServerUrl
	)
	try {
		$response = Invoke-WebRequest -Uri "$ServerUrl/health".Replace("/v1/chat/completions", "") -Method Get -UseBasicParsing -TimeoutSec 5
		return $response.StatusCode -eq 200
	} catch {
		return $false
	}
}

# Function to send a prompt to the vLLM server
function Invoke-VLLMRequest {
	param (
		[Parameter(Mandatory=$true)]
		[string]$Prompt
	)

	$messages = @()
	$currentDateTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
	$timezone = [System.TimeZoneInfo]::Local.DisplayName
	$locale = [System.Globalization.CultureInfo]::CurrentCulture.Name
	$geoHint = "Approximate location based on timezone ($timezone) and system locale ($locale)."
	$systemPrompt = "The current date and time is $currentDateTime. $geoHint. You have access to the conversation history for reference. Retain and use key details (e.g., specific numbers, names, or facts) from the history only when directly relevant to the current query. Do not mention or repeat details unless they are necessary to answer the user's question accurately. Respond naturally and concisely, ensuring you can recall stored information (like numbers) when explicitly asked."
	$messages += @{role = "system"; content = $systemPrompt}

	foreach ($msg in $conversationHistory) {
		$messages += @{role = $msg.role; content = $msg.content}
	}

	$messages += @{role = "user"; content = $Prompt}

	$payload = @{
		model = $Model
		messages = $messages
		max_tokens = $MaxTokens
		temperature = $Temperature
	} | ConvertTo-Json -Depth 10

	try {
		$response = Invoke-RestMethod -Uri $ServerUrl -Method Post -ContentType "application/json" -Body $payload
		$generatedText = $response.choices[0].message.content
		return $generatedText
	} catch {
		return "Error communicating with vLLM server: $_"
	}
}

# Function to parse ANSI color codes
function Parse-AnsiText {
    param([string]$text)

    $segments = @()
    $fore = 'White'
    $bold = $false
    $pos = 0
    $esc = [char]27

    while ($pos -lt $text.Length) {
        $matchPos = $text.IndexOf("$esc[", $pos)
        if ($matchPos -eq -1) {
            if ($pos -lt $text.Length) {
                $segments += @{text = $text.Substring($pos); color = $fore; bold = $bold}
            }
            break
        }
        if ($matchPos -gt $pos) {
            $segments += @{text = $text.Substring($pos, $matchPos - $pos); color = $fore; bold = $bold}
        }
        $endPos = $text.IndexOf('m', $matchPos + 2)
        if ($endPos -eq -1) { break }
        $codesStr = $text.Substring($matchPos + 2, $endPos - $matchPos - 2)
        $codes = $codesStr -split ';' | ForEach-Object { if ($_ -eq '') {0} else {[int]$_} }
        foreach ($c in $codes) {
            if ($c -eq 0) {
                $fore = 'White'
                $bold = $false
            } elseif ($c -eq 1) {
                $bold = $true
            } elseif (30 -le $c -and $c -le 37) {
                $colors = @('Black','Red','Green','Yellow','Blue','Magenta','Cyan','White')
                $fore = $colors[$c - 30]
            } elseif (90 -le $c -and $c -le 97) {
                $colors = @('Gray','Red','Green','Yellow','Blue','Magenta','Cyan','White')
                $fore = $colors[$c - 90]
            }
        }
        $pos = $endPos + 1
    }
    $segments
}

# Color map for brushes
$colorMap = @{
    'Black' = [System.Windows.Media.Brushes]::Black
    'Red' = [System.Windows.Media.Brushes]::Red
    'Green' = [System.Windows.Media.Brushes]::Green
    'Yellow' = [System.Windows.Media.Brushes]::Yellow
    'Blue' = [System.Windows.Media.Brushes]::Blue
    'Magenta' = [System.Windows.Media.Brushes]::Magenta
    'Cyan' = [System.Windows.Media.Brushes]::Cyan
    'White' = [System.Windows.Media.Brushes]::White
    'Gray' = [System.Windows.Media.Brushes]::Gray
}

# Add Text With Highlighting
function Add-TextWithHighlighting {
    param (
        [string]$Text,
        [System.Windows.Controls.RichTextBox]$RichTextBox
    )
    $lines = $Text -split "`n"
    $progressPrefixes = @("Capturing CUDA graphs", "cuda-repo.deb  ","`(Reading database ...")
    $lastWasProgress = $false
    foreach ($line in $lines) {
		if ($line -like "Redirecting output*") { $line = "" } #Cleanup wget display bug where wget-log redirection is announced
        $trimmed = $line.Trim() -replace '\0', ''
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        $isProgress = $false
        $isProgressWithTiming = $trimmed -match '^\[\d{2}:\d{2}<\d{2}:\d{2},\s*\d+\.\d+it/s\]'
        foreach ($prefix in $progressPrefixes) {
            if ($trimmed.StartsWith($prefix)) {
                $isProgress = $true
                break
            }
        }
        if (($isProgress -or $isProgressWithTiming) -and $RichTextBox.Document.Blocks.Count -gt 0) {
            $lastBlock = $RichTextBox.Document.Blocks.LastBlock
            if ($lastBlock -is [System.Windows.Documents.Paragraph]) {
                $lastText = [string]::Join('', ($lastBlock.Inlines | ForEach-Object { $_.Text }))
                $matched = $false
                foreach ($prefix in $progressPrefixes) {
                    if ($lastText.StartsWith($prefix)) {
                        $RichTextBox.Document.Blocks.Remove($lastBlock)
                        if ($lastWasProgress -and $RichTextBox.Document.Blocks.Count -gt 0) {
                            $prevBlock = $RichTextBox.Document.Blocks.LastBlock
                            if ($prevBlock -is [System.Windows.Documents.Paragraph]) {
                                $prevText = [string]::Join('', ($prevBlock.Inlines | ForEach-Object { $_.Text }))
                                if ($prevText -match '^\[\d{2}:\d{2}<\d{2}:\d{2},\s*\d+\.\d+it/s\]') {
                                    $RichTextBox.Document.Blocks.Remove($prevBlock)
                                }
                            }
                        }
                        $matched = $true
                        break
                    }
                }
                if (-not $matched -and $isProgressWithTiming -and $lastWasProgress) {
                    $RichTextBox.Document.Blocks.Remove($lastBlock)
                }
            }
        }
        $lastWasProgress = $isProgress -or $isProgressWithTiming
        if ($isProgressWithTiming) { continue }
        $paragraph = New-Object System.Windows.Documents.Paragraph
        $paragraph.Margin = New-Object System.Windows.Thickness(0)
        $segments = Parse-AnsiText -text $trimmed
        foreach ($seg in $segments) {
            $run = New-Object System.Windows.Documents.Run -ArgumentList $seg.text
            if ($seg.color -ne 'White' -and $colorMap.ContainsKey($seg.color)) {
                $run.Foreground = $colorMap[$seg.color]
            } else {
                $run.Foreground = [System.Windows.Media.Brushes]::LightGray
            }
            if ($seg.bold) {
                $run.FontWeight = [System.Windows.FontWeights]::Bold
            }
            $paragraph.Inlines.Add($run)
        }
        $RichTextBox.Document.Blocks.Add($paragraph)
    }
    $RichTextBox.ScrollToEnd()
}

# Function to highlight Markdown code blocks (for client responses)
function Add-ClientTextWithHighlighting {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Text,
        [Parameter(Mandatory=$true)]
        [Object]$RichTextBox
    )
    $paragraph = New-Object Windows.Documents.Paragraph
    $lines = $Text -split "`n"
    $inCodeBlock = $false
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { 
            $paragraph.Inlines.Add((New-Object System.Windows.Documents.LineBreak))
            continue 
        }
        $isBullet = $trimmed -match '^\s*\*\s+(.*)$'
        $bulletContent = if ($isBullet) { $Matches[1] } else { $trimmed }
        $run = New-Object System.Windows.Documents.Run
        $run.Text = $bulletContent + "`n"
        if ($line -match "^```.*") {
            $inCodeBlock = -not $inCodeBlock
            $run.Foreground = [Windows.Media.Brushes]::Gray
        }
        elseif ($inCodeBlock -or $line -match "^ {4}") {
            $run.Foreground = [Windows.Media.Brushes]::White
            $run.Background = [Windows.Media.Brushes]::Black
        }
        else {
            $run.Foreground = [Windows.Media.Brushes]::LightGray
        }
        $currentText = $run.Text
        $currentPos = 0
        $newInlines = @()
        while ($currentText -match '\*\*(.*?)\*\*' -and $currentPos -lt $currentText.Length) {
            $match = $currentText | Select-String -Pattern '\*\*(.*?)\*\*'
            $startPos = $match.Matches[0].Index
            $boldText = $match.Matches[0].Groups[1].Value
            $length = $match.Matches[0].Length
            if ($startPos -gt $currentPos) {
                $preRun = New-Object System.Windows.Documents.Run -ArgumentList $currentText.Substring($currentPos, $startPos - $currentPos)
                $preRun.Foreground = $run.Foreground
                $preRun.Background = $run.Background
                $newInlines += $preRun
            }
            $boldRun = New-Object System.Windows.Documents.Run -ArgumentList $boldText
            $boldRun.Foreground = $run.Foreground
            $boldRun.Background = $run.Background
            $boldRun.FontWeight = [System.Windows.FontWeights]::Bold
            $newInlines += $boldRun
            $currentPos = $startPos + $length
        }
        if ($currentPos -lt $currentText.Length) {
            $postRun = New-Object System.Windows.Documents.Run -ArgumentList $currentText.Substring($currentPos)
            $postRun.Foreground = $run.Foreground
            $postRun.Background = $run.Background
            $newInlines += $postRun
        }
        if ($isBullet) {
            $bulletRun = New-Object System.Windows.Documents.Run -ArgumentList "• "
            $bulletRun.Foreground = [System.Windows.Media.Brushes]::LightGray
            $paragraph.Inlines.Add($bulletRun)
            $paragraph.TextIndent = 10
        }
        foreach ($inline in $newInlines) {
            $paragraph.Inlines.Add($inline)
        }
    }
    $RichTextBox.Document.Blocks.Add($paragraph)
    $RichTextBox.ScrollToEnd()
}

# Short-term memory setup
$conversationHistory = New-Object System.Collections.ArrayList
$maxHistoryLength = 20

# Check WSL and Ubuntu installation
$wslInstalled = Get-Command wsl -ErrorAction SilentlyContinue
$ubuntuFound = $false
if ($ClientServerHybrid -and $wslInstalled) {
	$wslOutputRaw = & wsl --list --all --quiet
	if (-not [string]::IsNullOrEmpty($wslOutputRaw)) {
		$wslOutputBytes = [System.Text.Encoding]::UTF32.GetBytes($wslOutputRaw)
		$wslOutput = [System.Text.Encoding]::UTF8.GetString($wslOutputBytes) -split "\r?\n"
		$wslOutput | ForEach-Object {
			$cleaned = $_.Trim() -replace '[^\x20-\x7E]', ''
			if ($cleaned.ToLower() -like "*ubuntu-24.04*") {
				$ubuntuFound = $true
			}
		}
	}
}


if ($ubuntufound) {
	$online = $false
	$cacheBasePath = "~/.cache/huggingface/hub"
	$cacheFolder = "models--" + ($Model -replace "/", "--")
	$cachePath = "$cacheBasePath/$cacheFolder"
	$snapshotPath = & wsl -u root -d Ubuntu-24.04 -- bash -c "ls $cachePath/snapshots 2>/dev/null"
	if (-not $snapshotPath) {
		$online = $true
	} else {
		$snapshotFolder = ($snapshotPath -split "`n")[0].Trim()
	}
	if (-not $snapshotFolder) {
		$online = $true
	}
	if (-not $online){
		$Model = "$cachePath/snapshots/$snapshotFolder"
	}
	$modelIdentifier = $Model -Replace '^~' , '/root'
}

# Define WSL commands
if ($useFlashInfer) { $flashInferCmd = 'pip install flashinfer-python' } else { $flashInferCmd = "echo 'FlashInfer Installation Skipped - Unsupported System . . .'" }

$wslCommands = @"
sudo wget --show-progress --progress=bar:force:noscroll -O cuda-repo.deb https://developer.download.nvidia.com/compute/cuda/12.8.0/local_installers/cuda-repo-ubuntu2404-12-8-local_12.8.0-570.86.10-1_amd64.deb
sudo dpkg -i cuda-repo.deb
sudo cp /var/cuda-repo-ubuntu2404-12-8-local/cuda-*-keyring.gpg /usr/share/keyrings/
sudo apt-get update
sudo apt-get -y install cuda-toolkit-12-8
sudo apt-get -y install nvidia-open
sudo apt update
sudo apt upgrade -y
sudo apt install -y python3 python3-pip python3-venv git build-essential
cd ~
python3 -m venv vllm_env
source vllm_env/bin/activate
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
pip install vllm
pip install bitsandbytes
$flashInferCmd
"@ -replace "`r`n", "`n"

if ($quantization){ $quantCmd = "--quantization bitsandbytes --dtype float16"} else { $quantCmd = "" }

$wslCommandsStartup = @"
echo '#!/bin/bash' > ~/run_vllm.sh
echo 'source ~/vllm_env/bin/activate' >> ~/run_vllm.sh
echo 'vllm serve $Model --max-model-len $contextLength --gpu-memory-utilization $maxVRAM --port $ServerPort $quantCmd' >> ~/run_vllm.sh
chmod +x ~/run_vllm.sh
"@ -replace "`r`n", "`n"

# Show initial UI
$ui = Show-UI -Mode "Wait" -StatusMessage $(if (-not $ClientServerHybrid) { "...Waiting to Connect to Server..." } else { "...Please Wait..." })
$window = $ui.Window

# Set Window Icon, Taskbar Icon, and System Tray Icon using imported type def
try {
	$windowIcon = [System.IconExtractor]::Extract('C:\Windows\System32\netshell.dll', 94, $true)
	if ($windowIcon) {
		$bitmapSource = [System.IconExtractor]::IconToBitmapSource($windowIcon)
		$window.Icon = $bitmapSource
		$window.TaskbarItemInfo.Overlay = $bitmapSource
		$window.TaskbarItemInfo.Description = $AppId
		($window.FindName('WindowIconImage')).Source = $bitmapSource
		($window.FindName('WindowIconImage')).SetValue([System.Windows.Media.RenderOptions]::BitmapScalingModeProperty, [System.Windows.Media.BitmapScalingMode]::HighQuality)
		$sysTrayIcon = New-Object System.Windows.Forms.NotifyIcon
		$sysTrayIcon.Text = $AppId
		$sysTrayIcon.Icon = $windowIcon
		$sysTrayIcon.Visible = $false
		$sysTrayIcon.Add_Click({
			$sysTrayIcon.Visible = $false
			$window.Show()
		})
	}
} catch {
	[System.Windows.MessageBox]::Show("Error setting icons: $_", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
}

# Button Event Handlers
$ui.BtnMinimize.Add_Click({
	$window.Hide()
	if ($sysTrayIcon) { $sysTrayIcon.Visible = $true }
})

$ui.BtnCloseInner.Add_Click({
	$window.Close()
})

# DragMove Functionality
$ui.MainGrid.Add_MouseLeftButtonDown({
	if ($_.OriginalSource -isnot [System.Windows.Controls.TextBox] -and
		$_.OriginalSource -isnot [System.Windows.Controls.RichTextBox]) {
		$window.DragMove()
	}
})

# SendButtonOverlay to forward click to SendButton
$ui.SendButtonOverlay.Add_Click({
	if ($ui.SendButton.IsEnabled) {
		$ui.SendButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
	}
})

# Function to start polling runspace
function Start-PollingRunspace {
	param (
		[Object]$UI,
		[int]$TimeoutSeconds = 900,
		[switch]$FromLaunch = $false
	)

	$syncHash = [hashtable]::Synchronized(@{
		IsRunning = $false
		TimeoutOccurred = $false
		UI = $UI
		FromLaunch = $FromLaunch
		LastError = $null
		RunspaceError = $null
	})

	$runspace = [RunspaceFactory]::CreateRunspace()
	$runspace.ApartmentState = "MTA"
	$runspace.ThreadOptions = "ReuseThread"
	try {
		$runspace.Open()
	} catch {
		$syncHash.RunspaceError = "Failed to open runspace: $($_.Exception.Message)"
		$syncHash.UI.Window.Dispatcher.Invoke([Action]{
			$syncHash.UI.WaitText.Text = "Runspace initialization failed."
			[System.Windows.MessageBox]::Show($syncHash.RunspaceError, "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
			$syncHash.UI.Window.Dispatcher.Invoke([Action]{ $syncHash.UI.Window.Show() })
		})
		return
	}
	$runspace.SessionStateProxy.SetVariable("syncHash", $syncHash)
	$runspace.SessionStateProxy.SetVariable("ServerUrl", $ServerUrl)
	$runspace.SessionStateProxy.SetVariable("TimeoutSeconds", $TimeoutSeconds)

	$scriptBlock = {
		param($syncHash, $ServerUrl, $TimeoutSeconds)
		try {
			function Test-VllmRunning {
				param($ServerUrl)
				try {
					$response = Invoke-WebRequest -Uri "$ServerUrl/health".Replace("/v1/chat/completions", "") -Method Get -UseBasicParsing -TimeoutSec 5
					return $response.StatusCode -eq 200
				} catch {
					$syncHash.LastError = "Error at $(Get-Date): $($_.Exception.Message)"
					return $false
				}
			}

			$startTime = Get-Date
			while ($true) {
				if (Test-VllmRunning -ServerUrl $ServerUrl) {
					$syncHash.IsRunning = $true
					break
				}
				$elapsed = (Get-Date) - $startTime
				if ($elapsed.TotalSeconds -gt $TimeoutSeconds) {
					$syncHash.TimeoutOccurred = $true
					break
				}
				Start-Sleep -Seconds 1
			}
		} catch {
			$syncHash.RunspaceError = "Runspace script block failed: $($_.Exception.Message)"
		}
	}

	$ps = [PowerShell]::Create()
	try {
		$ps.Runspace = $runspace
		$ps.AddScript($scriptBlock).AddArgument($syncHash).AddArgument($ServerUrl).AddArgument($TimeoutSeconds)
	} catch {
		$syncHash.RunspaceError = "Failed to initialize PowerShell instance: $($_.Exception.Message)"
		$syncHash.UI.Window.Dispatcher.Invoke([Action]{
			$syncHash.UI.WaitText.Text = "Runspace initialization failed."
			[System.Windows.MessageBox]::Show($syncHash.RunspaceError, "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
			$syncHash.UI.Window.Dispatcher.Invoke([Action]{ $syncHash.UI.Window.Show() })
		})
		$runspace.Close()
		$ps.Dispose()
		return
	}

	$handle = $null
	try {
		$handle = $ps.BeginInvoke()
	} catch {
		$syncHash.RunspaceError = "Failed to start runspace: $($_.Exception.Message)"
		$syncHash.UI.Window.Dispatcher.Invoke([Action]{
			$syncHash.UI.WaitText.Text = "Runspace startup failed."
			[System.Windows.MessageBox]::Show($syncHash.RunspaceError, "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
			$syncHash.UI.Window.Dispatcher.Invoke([Action]{ $syncHash.UI.Window.Show() })
		})
		$runspace.Close()
		$ps.Dispose()
		return
	}

	# Completion handler
	$timer = New-Object System.Windows.Threading.DispatcherTimer
	$timer.Interval = [TimeSpan]::FromMilliseconds(1000)
	$timer.Add_Tick({
		if ($handle.IsCompleted) {
			try {
				$ps.EndInvoke($handle)
			} catch {
				$syncHash.RunspaceError = "Runspace terminated unexpectedly: $($_.Exception.Message)"
			}
			$timer.Stop()
			$syncHash.UI.Window.Dispatcher.Invoke([Action]{
				if ($syncHash.IsRunning) {
					$syncHash.UI.WaitPanel.Visibility = "Collapsed"
					$syncHash.UI.ClientPanelBorder.Visibility = "Visible"
					$syncHash.UI.GpuSelector.Visibility = "Collapsed"
					$syncHash.UI.WindowTitleText.Text = "MyAI vLLM Server/Client Hybrid"
					$syncHash.UI.Window.Show()
					Add-ClientTextWithHighlighting -Text "vLLM server is ready! You can now interact with the model." -RichTextBox $syncHash.UI.OutputTextBox
				} elseif ($syncHash.RunspaceError) {
					$syncHash.UI.WaitText.Text = "Runspace startup failed."
					$syncHash.UI.Window.Show()
					[System.Windows.MessageBox]::Show($syncHash.RunspaceError, "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
				} elseif ($syncHash.TimeoutOccurred) {
					$syncHash.UI.WaitText.Text = "Timeout waiting for vLLM server."
					$syncHash.UI.Window.Show()
					[System.Windows.MessageBox]::Show("Timeout waiting for vLLM server to start [15min]. Last error: $($syncHash.LastError).", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
				} else {
					$syncHash.UI.WaitText.Text = "Unexpected runspace termination."
					$syncHash.UI.Window.Show()
					[System.Windows.MessageBox]::Show("Unexpected runspace termination. Last error: $($syncHash.LastError).", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
				}
			})
			$runspace.Close()
			$ps.Dispose()
		}
	}.GetNewClosure())
	$timer.Start()

	return [PSCustomObject]@{
		PowerShell = $ps
		Handle = $handle
		Runspace = $runspace
		SyncHash = $syncHash
	}
}

# Start send request runspace
function Start-SendRequestRunspace {
	param (
		[Object]$UI,
		[string]$Prompt
	)

	$syncHash = [hashtable]::Synchronized(@{
		UI = $UI
		Prompt = $Prompt
		Result = $null
		ErrorMessage = $null
		ConversationHistory = $conversationHistory
		MaxHistoryLength = $maxHistoryLength
	})

	$runspace = [RunspaceFactory]::CreateRunspace()
	$runspace.ApartmentState = "MTA"
	$runspace.ThreadOptions = "ReuseThread"
	try {
		$runspace.Open()
	} catch {
		$syncHash.ErrorMessage = "Failed to open runspace: $($_.Exception.Message)"
		$syncHash.UI.Window.Dispatcher.Invoke([Action]{
			$syncHash.UI.SendButton.IsEnabled = $true
			Add-TextWithHighlighting -Text "Runspace initialization failed: $($syncHash.ErrorMessage)" -RichTextBox $syncHash.UI.OutputTextBox
		})
		return
	}

	$runspace.SessionStateProxy.SetVariable("syncHash", $syncHash)
	$runspace.SessionStateProxy.SetVariable("Model", $modelIdentifier)
	$runspace.SessionStateProxy.SetVariable("ServerUrl", $ServerUrl)
	$runspace.SessionStateProxy.SetVariable("MaxTokens", $MaxTokens)
	$runspace.SessionStateProxy.SetVariable("Temperature", $Temperature)

	$scriptBlock = {
		param($syncHash, $modelIdentifier, $ServerUrl, $MaxTokens, $Temperature)
		try {
			$messages = @()
			$currentDateTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
			$timezone = [System.TimeZoneInfo]::Local.DisplayName
			$locale = [System.Globalization.CultureInfo]::CurrentCulture.Name
			$geoHint = "Approximate location based on timezone ($timezone) and system locale ($locale)."
			$systemPrompt = "The current date and time is $currentDateTime. $geoHint. You have access to the conversation history for reference. Retain and use key details (e.g., specific numbers, names, or facts) from the history only when directly relevant to the current query. Do not mention or repeat details unless they are necessary to answer the user's question accurately. Respond naturally and concisely, ensuring you can recall stored information (like numbers) when explicitly asked."
			$messages += @{role = "system"; content = $systemPrompt}

			foreach ($msg in $syncHash.ConversationHistory) {
				$messages += @{role = $msg.role; content = $msg.content}
			}

			$messages += @{role = "user"; content = $syncHash.Prompt}

			$payload = @{
				model = $modelIdentifier
				messages = $messages
				max_tokens = $MaxTokens
				temperature = $Temperature
			} | ConvertTo-Json -Depth 10

			$response = Invoke-RestMethod -Uri $ServerUrl -Method Post -ContentType "application/json" -Body $payload
			$syncHash.Result = $response.choices[0].message.content
		} catch {
			$syncHash.ErrorMessage = "Error communicating with vLLM server: $($_.Exception.Message)"
		}
	}

	$ps = [PowerShell]::Create()
	try {
		$ps.Runspace = $runspace
		$ps.AddScript($scriptBlock).AddArgument($syncHash).AddArgument($modelIdentifier).AddArgument($ServerUrl).AddArgument($MaxTokens).AddArgument($Temperature)
	} catch {
		$syncHash.ErrorMessage = "Failed to initialize PowerShell instance: $($_.Exception.Message)"
		$syncHash.UI.Window.Dispatcher.Invoke([Action]{
			$syncHash.UI.SendButton.IsEnabled = $true
			Add-TextWithHighlighting -Text "Runspace initialization failed: $($syncHash.ErrorMessage)" -RichTextBox $syncHash.UI.OutputTextBox
		})
		$runspace.Close()
		$ps.Dispose()
		return
	}

	$handle = $null
	try {
		$handle = $ps.BeginInvoke()
	} catch {
		$syncHash.ErrorMessage = "Failed to start runspace: $($_.Exception.Message)"
		$syncHash.UI.Window.Dispatcher.Invoke([Action]{
			$syncHash.UI.SendButton.IsEnabled = $true
			Add-TextWithHighlighting -Text "Runspace startup failed: $($syncHash.ErrorMessage)" -RichTextBox $syncHash.UI.OutputTextBox
		})
		$runspace.Close()
		$ps.Dispose()
		return
	}

	return [PSCustomObject]@{
		PowerShell = $ps
		Handle = $handle
		Runspace = $runspace
		SyncHash = $syncHash
	}
}

# Determine initial state
$installType = ""
$modelName = $null
if ($ClientServerHybrid) {
	if (-not $wslInstalled -or -not $ubuntuFound) {
		$installType = "WSL"
		$ui.WaitPanel.Dispatcher.Invoke([Action]{
			$ui.WaitPanel.Visibility = "Collapsed"
			$ui.InstallPanel.Visibility = "Visible"
			$ui.GpuSelector.Visibility = "Collapsed"
			$ui.InstallStatusText.Text = "Install Ubuntu-24.04/vLLM and Dependencies"
		})
	} else {
		$scriptContent = & wsl ~ -u root -d Ubuntu-24.04 bash -c "cat ~/run_vllm.sh 2>/dev/null"
		foreach ($line in $scriptContent) {
			if ($line -like "*vllm serve*") {
				$fields = $line.Split(" ", [StringSplitOptions]::RemoveEmptyEntries)
				if ($fields.Count -ge 4) {
					$modelName = $fields[3].Trim('"') -Replace '~', '/root'
					break
				}
			}
		}
		if (-not $modelName) {
			$installType = "Dependencies"
			$ui.WaitPanel.Dispatcher.Invoke([Action]{
				$ui.WaitPanel.Visibility = "Collapsed"
				$ui.InstallPanel.Visibility = "Visible"
				$ui.GpuSelector.Visibility = "Collapsed"
				$ui.ModelNameText = "Collapsed"
				$ui.InstallStatusText.Text = "Install vLLM and Dependencies"
			})
		} else {
			$ui.WaitPanel.Dispatcher.Invoke([Action]{
				$ui.WaitPanel.Visibility = "Collapsed"
				$ui.LaunchPanel.Visibility = "Visible"
				$ui.GpuSelector.Visibility = "Visible"
				$ui.ModelNameText = "Visible"
			})
		}
	}
} else {
	if (Test-VllmRunning -ServerUrl $ServerUrl) {
		$ui.Window.Dispatcher.Invoke([Action]{
			$ui.WaitPanel.Visibility = "Collapsed"
			$ui.ClientPanelBorder.Visibility = "Visible"
			$ui.GpuSelector.Visibility = "Collapsed"
			$ui.WindowTitleText.Text = "MyAI vLLM Client"
			Add-TextWithHighlighting -Text "vLLM server is ready! You can now interact with the model." -RichTextBox $ui.OutputTextBox
		})
	} else {
		$pollingRunspace = Start-PollingRunspace -UI $ui
		$ui.WaitPanel.Dispatcher.Invoke([Action]{
			$ui.GpuSelector.Visibility = "Collapsed"
		})
	}
}

# Install click
$ui.InstallButton.Add_Click({
	$ui.windowTitleText.Text = "MyAI vLLM Launcher - Installing Environment... (this may take a while)"
	$ui.InstallButton.IsEnabled = $false
	$ui.InstallStatusText.Text = "...Installing... (this may take a few minutes)"
	$ui.InstallPanel.Visibility = "Collapsed"
	$ui.ClientPanelBorder.Visibility = "Visible"
	$ui.ClientTabControl.SelectedItem = $ui.ServerTab
	$ui.ServerTextBox.Document.Blocks.Clear()
	Add-TextWithHighlighting -Text "Starting installation process..." -RichTextBox $ui.ServerTextBox

	$syncHash = [hashtable]::Synchronized(@{
		UI = $ui
		Success = $false
		ErrorMessage = $null
		ModelName = $null
		Output = New-Object System.Collections.ArrayList
		Process = $null
	})

	$runspace = [RunspaceFactory]::CreateRunspace()
	$runspace.ApartmentState = "MTA"
	$runspace.ThreadOptions = "ReuseThread"
	try {
		$runspace.Open()
	} catch {
		$syncHash.ErrorMessage = "Failed to open runspace: $($_.Exception.Message)"
		$syncHash.UI.Window.Dispatcher.Invoke([Action]{
			$syncHash.UI.InstallStatusText.Text = "Error during installation."
			$syncHash.UI.InstallButton.IsEnabled = $true
			$syncHash.UI.Window.Show()
			Add-TextWithHighlighting -Text $syncHash.ErrorMessage -RichTextBox $syncHash.UI.ServerTextBox
			[System.Windows.MessageBox]::Show($syncHash.ErrorMessage, "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
		})
		return
	}

	$runspace.SessionStateProxy.SetVariable("syncHash", $syncHash)
	$runspace.SessionStateProxy.SetVariable("installType", $installType)
	$runspace.SessionStateProxy.SetVariable("wslCommands", $wslCommands)
	$runspace.SessionStateProxy.SetVariable("wslCommandsStartup", $wslCommandsStartup)

	$scriptBlock = {
		param($syncHash, $installType, $wslCommands, $wslCommandsStartup)
		try {
			# Unified handler for output and error
			$outputHandler = {
				param($sender, $eventArgs)
				if ($null -ne $eventArgs.Data -and $eventArgs.Data.Trim()) {
					$syncHash.Output.Add($eventArgs.Data.Trim()) | Out-Null
				}
			}

			function Invoke-WslCommand {
				param($Arguments, $Description)
				$syncHash.Output.Add($Description) | Out-Null
				$process = New-Object System.Diagnostics.Process
				$process.StartInfo.FileName = "wsl.exe"
				$process.StartInfo.Arguments = $Arguments
				$process.StartInfo.UseShellExecute = $false
				$process.StartInfo.RedirectStandardOutput = $true
				$process.StartInfo.RedirectStandardError = $true
				$process.StartInfo.CreateNoWindow = $true
				$process.StartInfo.WorkingDirectory = $env:TEMP

				Register-ObjectEvent -InputObject $process -EventName "OutputDataReceived" -Action $outputHandler -ErrorAction SilentlyContinue | Out-Null
				Register-ObjectEvent -InputObject $process -EventName "ErrorDataReceived" -Action $outputHandler -ErrorAction SilentlyContinue | Out-Null
				Register-ObjectEvent -InputObject $process -EventName "Exited" -Action {
					$syncHash.Output.Add("$($Event.MessageData) process exited with code: $($_.SourceArgs[0].ExitCode)") | Out-Null
				} -MessageData $Description -ErrorAction SilentlyContinue | Out-Null

				if (-not $process.Start()) {
					throw "Failed to start $Description process"
				}
				$syncHash.Process = $process
				$process.BeginOutputReadLine()
				$process.BeginErrorReadLine()
				while (-not $process.HasExited) {
					Start-Sleep -Milliseconds 100
				}
				if ($process.ExitCode -ne 0) {
					throw "$Description process exited with code $($process.ExitCode)"
				}
				$process.Close()
			}

			if ($installType -eq "WSL") {
				Invoke-WslCommand -Arguments "--install -d Ubuntu-24.04 --no-launch" -Description "Installing WSL and Ubuntu-24.04"

				& wsl -d Ubuntu-24.04 -u root -- bash -c 'useradd --create-home --shell /usr/bin/bash --user-group --groups adm,dialout,cdrom,floppy,sudo,audio,dip,video,plugdev,netdev --password `$(echo $rootPassword | openssl passwd -1 -stdin) user'
			} else {
				$syncHash.Output.Add('Installing dependencies...') | Out-Null
			}

			Invoke-WslCommand -Arguments "~ -u root -d Ubuntu-24.04 -- bash -c '$wslCommands 2>&1'"

			& wsl ~ -u root -d Ubuntu-24.04 -e bash -c "$wslCommandsStartup"

			$syncHash.Output.Add("Verifying run_vllm.sh...") | Out-Null
			$scriptContent = & wsl ~ -u root -d Ubuntu-24.04 bash -c "cat ~/run_vllm.sh 2>/dev/null"
			if ($LASTEXITCODE -ne 0) {
				throw "Failed to read run_vllm.sh, exit code: $LASTEXITCODE"
			}
			foreach ($line in $scriptContent) {
				if ($line -like "*vllm serve*") {
					$fields = $line.Split(" ", [StringSplitOptions]::RemoveEmptyEntries)
					if ($fields.Count -ge 4) {
						$syncHash.ModelName = $fields[3].Trim('"')
						$syncHash.Output.Add("Model name extracted: $($syncHash.ModelName)") | Out-Null
						break
					}
				}
			}
			if (-not $syncHash.ModelName) {
				throw "Failed to extract model name from run_vllm.sh"
			}
			$syncHash.Success = $true
		} catch {
			$syncHash.ErrorMessage = "Error during installation: $($_.Exception.Message)"
			$syncHash.Output.Add($syncHash.ErrorMessage) | Out-Null
		}
	}

	$ps = [PowerShell]::Create()
	try {
		$ps.Runspace = $runspace
		$ps.AddScript($scriptBlock).AddArgument($syncHash).AddArgument($installType).AddArgument($wslCommands).AddArgument($wslCommandsStartup)
	} catch {
		$syncHash.ErrorMessage = "Failed to initialize PowerShell instance: $($_.Exception.Message)"
		$syncHash.UI.Window.Dispatcher.Invoke([Action]{
			$syncHash.UI.InstallStatusText.Text = "Error during installation."
			$syncHash.UI.InstallButton.IsEnabled = $true
			$syncHash.UI.Window.Show()
			Add-TextWithHighlighting -Text $syncHash.ErrorMessage -RichTextBox $syncHash.UI.ServerTextBox
			[System.Windows.MessageBox]::Show($syncHash.ErrorMessage, "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
		})
		$runspace.Close()
		$ps.Dispose()
		return
	}

	$handle = $null
	try {
		$handle = $ps.BeginInvoke()
	} catch {
		$syncHash.ErrorMessage = "Failed to start runspace: $($_.Exception.Message)"
		$syncHash.UI.Window.Dispatcher.Invoke([Action]{
			$syncHash.UI.InstallStatusText.Text = "Error during installation."
			$syncHash.UI.InstallButton.IsEnabled = $true
			$syncHash.UI.Window.Show()
			Add-TextWithHighlighting -Text $syncHash.ErrorMessage -RichTextBox $syncHash.UI.ServerTextBox
			[System.Windows.MessageBox]::Show($syncHash.ErrorMessage, "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
		})
		$runspace.Close()
		$ps.Dispose()
		return
	}

	$timer = New-Object System.Windows.Threading.DispatcherTimer
	$timer.Interval = [TimeSpan]::FromMilliseconds(100)
	$timer.Add_Tick({
		if ($handle.IsCompleted) {
			try {
				$ps.EndInvoke($handle)
			} catch {
				$syncHash.ErrorMessage = "Runspace terminated unexpectedly: $($_.Exception.Message)"
			}
			$timer.Stop()
			$ui.InstallButton.Dispatcher.Invoke([Action]{
				if ($syncHash.Output.Count -gt 0) {
					foreach ($line in $syncHash.Output) {
						Add-TextWithHighlighting -Text $line -RichTextBox $syncHash.UI.ServerTextBox
					}
					$syncHash.Output.Clear()
				}
				$ui.InstallButton.IsEnabled = $true
				$ui.Window.Show()
				if ($syncHash.Success -and $syncHash.ModelName) {
					$ui.windowTitleText.Text = "MyAI vLLM Launcher"
					$ui.ModelNameText = "Visible"
					$ui.GpuSelector.Visibility = "Visible"
					$ui.ClientPanelBorder.Visibility = "Collapsed"
					$ui.LaunchPanel.Visibility = "Visible"
				} else {
					$ui.InstallStatusText.Text = "Install Dependencies"
					$ui.InstallPanel.Visibility = "Visible"
					$ui.ClientPanelBorder.Visibility = "Collapsed"
					$errorMsg = if ($syncHash.ErrorMessage) { $syncHash.ErrorMessage } else { "Something went wrong. Please try installing again." }
					Add-TextWithHighlighting -Text $errorMsg -RichTextBox $syncHash.UI.ServerTextBox
					[System.Windows.MessageBox]::Show($errorMsg, "Warning", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
				}
			})
			$runspace.Close()
			$ps.Dispose()
		} else {
			$syncHash.UI.ServerTextBox.Dispatcher.Invoke([Action]{
				if ($syncHash.Output.Count -gt 0) {
					foreach ($line in $syncHash.Output) {
						Add-TextWithHighlighting -Text $line -RichTextBox $syncHash.UI.ServerTextBox
					}
					$syncHash.Output.Clear()
				}
			})
		}
	}.GetNewClosure())
	$timer.Start()
})

# LaunchButton click
$ui.LaunchButton.Add_Click({
	$ui.windowTitleText.Text = "MyAI vLLM Launcher - Loading Model... (this may take a while)"
	$ui.LaunchButton.IsEnabled = $false
	$ui.GpuSelector.Visibility = "Collapsed"
	$ui.StatusText.Text = "...Launching Model... (this may take a while)"
	if ($ClientServerHybrid) {
		$ui.LaunchPanel.Visibility = "Collapsed"
		$ui.ClientPanelBorder.Visibility = "Visible"
		$ui.ClientTabControl.SelectedItem = $ui.ServerTab
		$ui.ServerTextBox.Document.Blocks.Clear()  # Clear previous content
		Add-TextWithHighlighting -Text "Starting launch process..." -RichTextBox $ui.ServerTextBox
	}

	$syncHash = [hashtable]::Synchronized(@{
		UI = $ui
		Success = $false
		ErrorMessage = $null
		IsRunning = $false
		TimeoutOccurred = $false
		LastError = $null
		Output = New-Object System.Collections.ArrayList
		Process = $null
		ShownClient = $false
	})

	$runspace = [RunspaceFactory]::CreateRunspace()
	$runspace.ApartmentState = "MTA"
	$runspace.ThreadOptions = "ReuseThread"
	try {
		$runspace.Open()
	} catch {
		$syncHash.ErrorMessage = "Failed to open runspace: $($_.Exception.Message)"
		$syncHash.UI.Window.Dispatcher.Invoke([Action]{
			$syncHash.UI.StatusText.Text = "Ready to launch model"
			$syncHash.UI.LaunchButton.IsEnabled = $true
			$syncHash.UI.GpuSelector.Visibility = "Visible"
			$syncHash.UI.Window.Show()
			if ($ClientServerHybrid) {
				Add-TextWithHighlighting -Text $syncHash.ErrorMessage -RichTextBox $syncHash.UI.ServerTextBox
			}
			[System.Windows.MessageBox]::Show($syncHash.ErrorMessage, "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
		})
		return
	}

	$runspace.SessionStateProxy.SetVariable("syncHash", $syncHash)
	$runspace.SessionStateProxy.SetVariable("Model", $Model)
	$runspace.SessionStateProxy.SetVariable("contextLength", $contextLength)
	$runspace.SessionStateProxy.SetVariable("maxVRAM", $maxVRAM)
	$runspace.SessionStateProxy.SetVariable("ServerPort", $ServerPort)
	$runspace.SessionStateProxy.SetVariable("ServerUrl", $ServerUrl)
	$runspace.SessionStateProxy.SetVariable("selectedGpuIndex", $script:selectedGpuIndex)
	$runspace.SessionStateProxy.SetVariable("localOnly", $localOnly)

	$wslCommandsStartup = @"
echo '#!/bin/bash' > ~/run_vllm.sh
echo 'source ~/vllm_env/bin/activate' >> ~/run_vllm.sh
echo 'CUDA_VISIBLE_DEVICES=$selectedGpuIndex vllm serve $Model --quantization bitsandbytes --dtype float16 --max-model-len $contextLength --gpu-memory-utilization $maxVRAM --port $ServerPort' >> ~/run_vllm.sh
chmod +x ~/run_vllm.sh
"@ -replace "`r`n", "`n"

	$scriptBlock = {
		param($syncHash, $wslCommandsStartup, $Model, $contextLength, $maxVRAM, $ServerPort, $ServerUrl, $selectedGpuIndex, $localOnly)
		try {
			$syncHash.Output.Add("Validating model path: $Model") | Out-Null
			& wsl ~ -u root -d Ubuntu-24.04 test -d "$Model"; if ($LASTEXITCODE -eq 0) { $modelExists = 'exists locally..' } else { $modelExists = 'will be downloaded..(This may take a while)' }
			$syncHash.Output.Add("Model $modelExists") | Out-Null

			# Set up port redirection and firewall for WSL in hybrid mode
			if (-not $localOnly) {
				try {
					$syncHash.Output.Add("Setting up port forwarding and firewall...") | Out-Null
					# Wait for WSL network to stabilize
					Start-Sleep -Seconds 2
					$wslOutput = & wsl ~ -u root -d Ubuntu-24.04 bash -c "ip addr show eth0 | grep 'inet ' | head -n1 | awk '{print $2}' | cut -d'/' -f1 | sed 's/.* //'"
					if ($wslOutput -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
						$syncHash.Output.Add("WSL IP: $wslOutput") | Out-Null
						& netsh interface portproxy delete v4tov4 listenport=$ServerPort listenaddress=0.0.0.0 | Out-Null
						& netsh interface portproxy add v4tov4 listenport=$ServerPort listenaddress=0.0.0.0 connectport=$ServerPort connectaddress=$wslOutput | Out-Null
						$existingRule = Get-NetFirewallRule -DisplayName "MyAI WSL Port $ServerPort" -ErrorAction SilentlyContinue
						if (-not $existingRule) {
							New-NetFirewallRule -DisplayName "MyAI WSL Port $ServerPort" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $ServerPort | Out-Null
							$syncHash.Output.Add("Firewall rule created for port $ServerPort") | Out-Null
						} else {
							$syncHash.Output.Add("Firewall rule already exists for port $ServerPort") | Out-Null
						}
					} else {
						$syncHash.ErrorMessage = "Failed to extract valid WSL IP address for port forwarding: $wslOutput"
						$syncHash.Output.Add($syncHash.ErrorMessage) | Out-Null
						return
					}
				} catch {
					$syncHash.ErrorMessage = "Error setting up port redirection/firewall: $($_.Exception.Message)"
					$syncHash.Output.Add($syncHash.ErrorMessage) | Out-Null
					return
				}
			} else {
				$syncHash.Output.Add("Running in local-only mode, skipping port forwarding") | Out-Null
			}

			# Execute WSL commands to set up run_vllm.sh
			$syncHash.Output.Add("Adding startup configuration...") | Out-Null
			& wsl ~ -u root -d Ubuntu-24.04 -e bash -c $wslCommandsStartup
			if ($LASTEXITCODE -ne 0) {
				$syncHash.ErrorMessage = "Failed to set up run_vllm.sh, exit code: $LASTEXITCODE"
				$syncHash.Output.Add($syncHash.ErrorMessage) | Out-Null
				return
			}
			# Verify script exists
			& wsl ~ -u root -d Ubuntu-24.04 test -f '~/run_vllm.sh'
			if ($LASTEXITCODE -eq 0) {
				$scriptExists = "is ready.."
			} else {
				$scriptExists = "is missing.."
			}
			$syncHash.Output.Add("run_vllm.sh $scriptExists") | Out-Null
			if ($scriptExists -eq 'is missing..') {
				$syncHash.ErrorMessage = "Startup config script is missing!"
				$syncHash.Output.Add($syncHash.ErrorMessage) | Out-Null
				return
			}
			$syncHash.Output.Add("Ready to start vLLM server!") | Out-Null

			# Start vLLM server, capture output
			$syncHash.Output.Add("Starting vLLM server...") | Out-Null
			$process = New-Object System.Diagnostics.Process
			$process.StartInfo.FileName = "wsl.exe"
			$process.StartInfo.Arguments = "~ -u root -d Ubuntu-24.04 -- bash -c '~/run_vllm.sh 2>&1'"
			$process.StartInfo.UseShellExecute = $false
			$process.StartInfo.RedirectStandardOutput = $true
			$process.StartInfo.RedirectStandardError = $false  # stderr merged into stdout via 2>&1
			$process.StartInfo.CreateNoWindow = $true
			$process.StartInfo.WorkingDirectory = $env:TEMP

			$outputHandler = {
				param($sender, $eventArgs)
				if ($null -ne $eventArgs.Data -and $eventArgs.Data.Trim()) {
					$syncHash.Output.Add($eventArgs.Data.Trim()) | Out-Null
				}
			}

			Register-ObjectEvent -InputObject $process -EventName "OutputDataReceived" -Action $outputHandler -ErrorAction SilentlyContinue | Out-Null
			Register-ObjectEvent -InputObject $process -EventName "Exited" -Action {
				$syncHash.Output.Add("vLLM server process exited with code: $($_.SourceArgs[0].ExitCode)") | Out-Null
			} -ErrorAction SilentlyContinue | Out-Null

			try {
				if (-not $process.Start()) {
					throw "Failed to start WSL process"
				}
				$syncHash.Process = $process
				$syncHash.Output.Add("WSL process started (PID: $($process.Id))") | Out-Null
				$process.BeginOutputReadLine()
			} catch {
				$syncHash.ErrorMessage = "Failed to start WSL process: $($_.Exception.Message)"
				$syncHash.Output.Add($syncHash.ErrorMessage) | Out-Null
				$syncHash.ShouldPollOutput = $false
				return
			}

			# readiness/monitoring loop
			$startTime = Get-Date
			$timeoutSeconds = 900
			$serverReady = $false
			while (-not $process.HasExited) {
				if (-not $serverReady) {
					try {
						$response = Invoke-WebRequest -Uri "$ServerUrl/health".Replace("/v1/chat/completions", "") -Method Get -UseBasicParsing -TimeoutSec 5
						if ($response.StatusCode -eq 200) {
							$syncHash.IsRunning = $true
							$syncHash.Success = $true
							$syncHash.Output.Add("vLLM server is running (health check passed)") | Out-Null
							$serverReady = $true
						}
					} catch {
						$syncHash.LastError = "Health check failed: $($_.Exception.Message)"
					}

					$elapsed = (Get-Date) - $startTime
					if ($elapsed.TotalSeconds -gt $timeoutSeconds) {
						$syncHash.TimeoutOccurred = $true
						$syncHash.Output.Add("Timeout waiting for vLLM server to start [15min]") | Out-Null
						break  # End loop on timeout, end runspace
					}
				}
				Start-Sleep -Milliseconds 500
			}

			if ($process.HasExited -and -not $syncHash.IsRunning) {
				$syncHash.ErrorMessage = "vLLM server process exited unexpectedly (Exit code: $($process.ExitCode))"
				$syncHash.Output.Add($syncHash.ErrorMessage) | Out-Null
			}
		} catch {
			$syncHash.ErrorMessage = "Error in launch script block: $($_.Exception.Message)"
			$syncHash.Output.Add($syncHash.ErrorMessage) | Out-Null
			$syncHash.Output.Add("Stack trace: $($_.ScriptStackTrace)") | Out-Null
		}
	}

	$ps = [PowerShell]::Create()
	try {
		$ps.Runspace = $runspace
		$ps.AddScript($scriptBlock).AddArgument($syncHash).AddArgument($wslCommandsStartup).AddArgument($Model).AddArgument($contextLength).AddArgument($maxVRAM).AddArgument($ServerPort).AddArgument($ServerUrl).AddArgument($script:selectedGpuIndex).AddArgument($localOnly)
	} catch {
		$syncHash.ErrorMessage = "Failed to initialize PowerShell instance: $($_.Exception.Message)"
		$syncHash.UI.Window.Dispatcher.Invoke([Action]{
			$syncHash.UI.StatusText.Text = "Ready to launch model"
			$syncHash.UI.LaunchButton.IsEnabled = $true
			$syncHash.UI.GpuSelector.Visibility = "Visible"
			$syncHash.UI.Window.Show()
			if ($ClientServerHybrid) {
				Add-TextWithHighlighting -Text $syncHash.ErrorMessage -RichTextBox $syncHash.UI.ServerTextBox
			}
			[System.Windows.MessageBox]::Show($syncHash.ErrorMessage, "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
		})
		$runspace.Close()
		$ps.Dispose()
		return
	}

	$handle = $null
	try {
		$handle = $ps.BeginInvoke()
	} catch {
		$syncHash.ErrorMessage = "Failed to start runspace: $($_.Exception.Message)"
		$syncHash.UI.Window.Dispatcher.Invoke([Action]{
			$syncHash.UI.StatusText.Text = "Ready to launch model"
			$syncHash.UI.LaunchButton.IsEnabled = $true
			$syncHash.UI.GpuSelector.Visibility = "Visible"
			$syncHash.UI.Window.Show()
			if ($ClientServerHybrid) {
				Add-TextWithHighlighting -Text $syncHash.ErrorMessage -RichTextBox $syncHash.UI.ServerTextBox
			}
			[System.Windows.MessageBox]::Show($syncHash.ErrorMessage, "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
		})
		$runspace.Close()
		$ps.Dispose()
		return
	}

	$timer = New-Object System.Windows.Threading.DispatcherTimer
	$timer.Interval = [TimeSpan]::FromMilliseconds(100)
	$timer.Add_Tick({
		if ($handle.IsCompleted) {
			try {
				$ps.EndInvoke($handle)
			} catch {
				$syncHash.ErrorMessage = "Runspace terminated unexpectedly: $($_.Exception.Message)"
			}
			$timer.Stop()
			$syncHash.UI.Window.Dispatcher.Invoke([Action]{
				# Flush final output
				if ($syncHash.Output.Count -gt 0) {
					foreach ($line in $syncHash.Output) {
						Add-TextWithHighlighting -Text $line -RichTextBox $syncHash.UI.ServerTextBox
					}
					$syncHash.Output.Clear()
				}
				if ($syncHash.ErrorMessage) {
					Add-TextWithHighlighting -Text $syncHash.ErrorMessage -RichTextBox $syncHash.UI.ServerTextBox
					[System.Windows.MessageBox]::Show($syncHash.ErrorMessage, "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
				} elseif ($syncHash.TimeoutOccurred) {
					Add-TextWithHighlighting -Text "Timeout waiting for vLLM server to start [15min]. Last error: $($syncHash.LastError). Check the Server WSL terminal for errors (e.g., GPU issues, model download failure)." -RichTextBox $syncHash.UI.ServerTextBox
					[System.Windows.MessageBox]::Show("Timeout waiting for vLLM server to start [15min]. Last error: $($syncHash.LastError). Check the Server WSL terminal for errors (e.g., GPU issues, model download failure).", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
					# Reset to launch on timeout
					$syncHash.UI.StatusText.Text = "Ready to launch model"
					$syncHash.UI.LaunchButton.IsEnabled = $true
					$syncHash.UI.GpuSelector.Visibility = "Visible"
					$syncHash.UI.LaunchPanel.Visibility = "Visible"
					$syncHash.UI.ClientPanelBorder.Visibility = "Collapsed"
					$syncHash.UI.ClientTab.Visibility = "Collapsed"
				} else {
					Add-TextWithHighlighting -Text "vLLM server has stopped." -RichTextBox $syncHash.UI.ServerTextBox
				}
			})
			$runspace.Close()
			$ps.Dispose()
		} else {
			$syncHash.UI.ServerTextBox.Dispatcher.Invoke([Action]{
				if ($syncHash.Output.Count -gt 0) {
					foreach ($line in $syncHash.Output) {
						Add-TextWithHighlighting -Text $line -RichTextBox $syncHash.UI.ServerTextBox
					}
					$syncHash.Output.Clear()
				}
			})
			if ($syncHash.IsRunning -and -not $syncHash.ShownClient) {
				$syncHash.ShownClient = $true
				$syncHash.UI.Window.Dispatcher.Invoke([Action]{
					$syncHash.UI.WaitPanel.Visibility = "Collapsed"
					$syncHash.UI.LaunchPanel.Visibility = "Collapsed"
					$syncHash.UI.ClientPanelBorder.Visibility = "Visible"
					$syncHash.UI.GpuSelector.Visibility = "Collapsed"
					if ($localOnly) {
						$syncHash.UI.WindowTitleText.Text = "MyAI vLLM Client/Server Hybrid - Local Mode"
					} else {
						$route = Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Select-Object -First 1
						$global:gateway = $route.NextHop
						$gatewayParts = $global:gateway -split '\.'
						$gatewayPrefix = (($gatewayParts[0..2] -join '.') + '.')
						$ProgressPreference = 'SilentlyContinue'
						try {
							$ncsiCheck = Invoke-RestMethod "http://www.msftncsi.com/ncsi.txt"
							if ($ncsiCheck -eq "Microsoft NCSI") {
								$getIPv4Address = ([System.Net.Dns]::GetHostAddresses("ifconfig.me") | Where-Object { $_.AddressFamily -eq "InterNetwork" }).IPAddressToString
								$externalIP = Invoke-RestMethod -Uri "https://$getIPv4Address/ip" -Headers @{ Host = "ifconfig.me" }
							} else {
								$externalIP = "Unknown"
							}
						} catch {
							$externalIP = "No Internet"
						}
						$ProgressPreference = 'Continue'
						$internalIP = (Get-NetIPAddress | Where-Object {
							$_.AddressFamily -eq 'IPv4' -and
							$_.InterfaceAlias -ne 'Loopback Pseudo-Interface 1' -and
							$_.IPAddress -like "$gatewayPrefix*"
						}).IPAddress
						$syncHash.UI.WindowTitleText.Text = "MyAI vLLM Client/Server Hybrid - External IP: ${externalIP}:$ServerPort - Internal IP: ${internalIP}:$ServerPort"
					}
					$syncHash.UI.ClientTab.Visibility = "Visible"
					$syncHash.UI.ClientTabControl.SelectedItem = $syncHash.UI.ClientTab
					$syncHash.UI.Window.Show()
					Add-ClientTextWithHighlighting -Text "vLLM server is ready! You can now interact with the model." -RichTextBox $syncHash.UI.OutputTextBox
				})
			}
		}
	}.GetNewClosure())
	$timer.Start()

	# Cleanup on window close
	$ui.Window.Add_Closing({
		if ($syncHash.Process -and -not $syncHash.Process.HasExited) {
			try { $syncHash.Process.Kill() } catch { }
			$syncHash.Process.Dispose()
		}
		Get-EventSubscriber | Where-Object { $_.SourceObject -eq $syncHash.Process } | Unregister-Event -Force | Out-Null
	})
})

# Send button click
$ui.SendButton.Add_Click({
	if ($ui.SendButton.IsEnabled -eq $false) { return }
	$ui.SendButton.IsEnabled = $false
	$prompt = $ui.InputTextBox.Text
	if ([string]::IsNullOrWhiteSpace($prompt)) {
		Add-ClientTextWithHighlighting -Text "Prompt cannot be empty. Please try again." -RichTextBox $ui.OutputTextBox
		$ui.SendButton.IsEnabled = $true
		return
	}

	Add-ClientTextWithHighlighting -Text "Prompt: $prompt" -RichTextBox $ui.OutputTextBox
	$conversationHistory.Add(@{role = "user"; content = $prompt}) | Out-Null
	$ui.InputTextBox.Text = ""

	$sendRunspace = Start-SendRequestRunspace -UI $ui -Prompt $prompt
	if (-not $sendRunspace) { return }

	$ps = $sendRunspace.PowerShell
	$handle = $sendRunspace.Handle
	$runspace = $sendRunspace.Runspace
	$syncHash = $sendRunspace.SyncHash

	$timer = New-Object System.Windows.Threading.DispatcherTimer
	$timer.Interval = [TimeSpan]::FromMilliseconds(1000)
	$timer.Add_Tick({
		if ($handle.IsCompleted) {
			try {
				$ps.EndInvoke($handle)
			} catch {
				$syncHash.ErrorMessage = "Runspace terminated unexpectedly: $($_.Exception.Message)"
			}
			$timer.Stop()
			$ui.SendButton.Dispatcher.Invoke([Action]{
				if ($syncHash.Result -and -not $syncHash.ErrorMessage) {
					Add-ClientTextWithHighlighting -Text "Response:`n$($syncHash.Result)" -RichTextBox $ui.OutputTextBox
					$syncHash.ConversationHistory.Add(@{role = "assistant"; content = $syncHash.Result}) | Out-Null
					if ($syncHash.ConversationHistory.Count -gt $syncHash.MaxHistoryLength * 2) {
						$syncHash.ConversationHistory = $syncHash.ConversationHistory | Select-Object -Last ($syncHash.MaxHistoryLength * 2)
					}
				} else {
					Add-ClientTextWithHighlighting -Text "Failed to get a response from the server: $($syncHash.ErrorMessage)" -RichTextBox $ui.OutputTextBox
				}
				$ui.SendButton.IsEnabled = $true
			})
			$runspace.Close()
			$ps.Dispose()
		}
	}.GetNewClosure())
	$timer.Start()
})

# Closing actions
$window.Add_Closing({
	try {
		if ($ClientServerHybrid) {
			& wsl ~ -u root -d Ubuntu-24.04 -e pkill -INT -f "vllm serve"
			if (-not $localOnly) {
				& netsh interface portproxy delete v4tov4 listenport=$ServerPort listenaddress=0.0.0.0 | Out-Null
				Remove-NetFirewallRule -DisplayName "MyAI WSL Port $ServerPort" -ErrorAction SilentlyContinue
			}
		}
		if ($syncHash.Process -and -not $syncHash.Process.HasExited) {
			try { $syncHash.Process.Kill() } catch { }
			$syncHash.Process.Dispose()
		}
		Get-EventSubscriber | Where-Object { $_.SourceObject -eq $syncHash.Process } | Unregister-Event -Force | Out-Null
		$conversationHistory.Clear()
		if ($sysTrayIcon) { $sysTrayIcon.Dispose() }
		[System.Windows.Threading.Dispatcher]::ExitAllFrames() | Out-Null
	} catch {
		[System.Windows.MessageBox]::Show("Error during cleanup: $_", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
	}
})

$application = New-Object System.Windows.Application
$application.Run($window)