$ErrorActionPreference = "Stop"
$InformationPreference = "Continue"

$repoRawBase = "https://raw.githubusercontent.com/alexiszamanidis/windows"
$packagesFile = if ($PSScriptRoot) {
    Join-Path $PSScriptRoot "packages.txt"
} else {
    Join-Path $env:TEMP "windows-packages.txt"
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Information "Administrator permission is required. Restarting elevated..."
    if ($PSCommandPath) {
        $argumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath)
    } else {
        $argumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "irm $repoRawBase/master/install.ps1 | iex")
    }
    Start-Process -FilePath "powershell" -Verb RunAs -ArgumentList $argumentList | Out-Null
    exit 0
}

if (-not (Test-Path $packagesFile)) {
    Write-Information "packages.txt not found locally. Downloading from GitHub..."
    try {
        Invoke-WebRequest -Uri "$repoRawBase/master/packages.txt" -OutFile $packagesFile -UseBasicParsing
    } catch {
        throw "packages.txt not found at $packagesFile and download from GitHub failed."
    }
}

$packages = Get-Content $packagesFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") }

function Set-DarkMode {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $personalizePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    if (-not $PSCmdlet.ShouldProcess($personalizePath, "Set Windows and app color mode to Dark")) {
        return
    }

    New-Item -Path $personalizePath -Force | Out-Null
    New-ItemProperty -Path $personalizePath -Name "AppsUseLightTheme" -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $personalizePath -Name "SystemUsesLightTheme" -PropertyType DWord -Value 0 -Force | Out-Null

    if (-not ([System.Management.Automation.PSTypeName]"WindowsSetup.ThemeNativeMethods").Type) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace WindowsSetup {
    public static class ThemeNativeMethods {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint message, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);
    }
}
"@
    }

    $broadcastResult = [IntPtr]::Zero
    [void][WindowsSetup.ThemeNativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [IntPtr]::Zero, "ImmersiveColorSet", 0x0002, 5000, [ref]$broadcastResult)

    Write-Information "Windows and app color mode set to Dark."
}

function Set-DesktopWallpaper {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $wallpaperName = "black-cat-dual-monitor-wallpaper.jpg"
    $wallpaperPath = Join-Path (Join-Path $env:APPDATA "WindowsSetup") $wallpaperName
    if (-not $PSCmdlet.ShouldProcess($wallpaperPath, "Set desktop wallpaper")) {
        return
    }

    $localWallpaperPath = if ($PSScriptRoot) {
        Join-Path $PSScriptRoot $wallpaperName
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $wallpaperPath) -Force | Out-Null
    if ($localWallpaperPath -and (Test-Path -LiteralPath $localWallpaperPath)) {
        Copy-Item -LiteralPath $localWallpaperPath -Destination $wallpaperPath -Force
    } else {
        Write-Information "Downloading desktop wallpaper..."
        Invoke-WebRequest -Uri "$repoRawBase/master/$wallpaperName" -OutFile $wallpaperPath -UseBasicParsing
    }

    $desktopSettings = "HKCU:\Control Panel\Desktop"
    Set-ItemProperty -Path $desktopSettings -Name "WallpaperStyle" -Value "22"
    Set-ItemProperty -Path $desktopSettings -Name "TileWallpaper" -Value "0"

    if (-not ([System.Management.Automation.PSTypeName]"WindowsSetup.WallpaperNativeMethods").Type) {
        Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace WindowsSetup {
    public static class WallpaperNativeMethods {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SystemParametersInfo(uint action, uint parameter, string value, uint flags);
    }
}
"@
    }

    # SPI_SETDESKWALLPAPER with SPIF_UPDATEINIFILE | SPIF_SENDCHANGE.
    if (-not [WindowsSetup.WallpaperNativeMethods]::SystemParametersInfo(20, 0, $wallpaperPath, 3)) {
        $win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw [ComponentModel.Win32Exception]::new($win32Error, "Failed to set the desktop wallpaper.")
    }

    Write-Information "Desktop wallpaper set to $wallpaperName."
}

Set-DarkMode
Set-DesktopWallpaper

if ($packages.Count -eq 0) {
    Write-Information "packages.txt has no package IDs yet."
    exit 0
}

# 0x8A15002B: package is already installed and no newer version is available.
$wingetUpdateNotApplicable = -1978335189
# 0x8A15010C: Inno Setup aborted a suppressed prompt and WinGet reports it as cancelled.
$wingetInstallCancelled = -1978334964

function Stop-InputLeapProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess("Input Leap")) {
        return
    }

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    foreach ($name in @("input-leap", "input-leapd", "input-leapc", "input-leaps")) {
        Get-Process -Name $name | Stop-Process -Force
    }
    Stop-Service -Name "InputLeap" -Force
    $ErrorActionPreference = $previousErrorAction
}

function Install-WinGetPackage {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Id)

    if (-not $PSCmdlet.ShouldProcess($Id)) {
        return 0
    }

    $arguments = @(
        "install",
        "--id", $Id,
        "--exact",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity"
    )

    if ($Id -eq "input-leap.input-leap") {
        # The silent installer exits 5 when it cannot close a program using its files.
        Stop-InputLeapProcess
        $arguments += @("--silent", "--custom", "/FORCECLOSEAPPLICATIONS")
    }

    & winget @arguments | Out-Host
    return $LASTEXITCODE
}

foreach ($id in $packages) {
    Write-Information "Installing $id"
    $exitCode = Install-WinGetPackage $id
    if ($id -eq "input-leap.input-leap" -and $exitCode -eq $wingetInstallCancelled) {
        Write-Information "Input Leap installer aborted. Closing its processes and retrying."
        $exitCode = Install-WinGetPackage $id
    }
    if ($exitCode -eq $wingetUpdateNotApplicable) {
        Write-Information "$id is already installed and up to date."
        continue
    }
    if ($exitCode -ne 0) {
        throw "WinGet failed to install $id (exit code $exitCode)."
    }
}
