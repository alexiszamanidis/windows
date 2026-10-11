function Set-DarkMode {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $personalizePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    if (-not $PSCmdlet.ShouldProcess($personalizePath, "Set Windows and app color mode to Dark")) {
        return
    }

    # New-Item -Force on an existing registry key deletes its values.
    # Recreating Personalize makes Windows fall back to light mode, and Cursor follows that.
    if (-not (Test-Path -LiteralPath $personalizePath)) {
        New-Item -Path $personalizePath | Out-Null
    }
    New-ItemProperty -Path $personalizePath -Name "AppsUseLightTheme" -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $personalizePath -Name "SystemUsesLightTheme" -PropertyType DWord -Value 0 -Force | Out-Null
    Invoke-ThemeBroadcast
    Write-Information "Windows and app color mode set to Dark."
}

function Invoke-ThemeBroadcast {
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
}

function Set-DesktopWallpaper {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $wallpaperName = "black-cat-dual-monitor-wallpaper.jpg"
    $wallpaperPath = Join-Path (Join-Path $env:APPDATA "WindowsSetup") $wallpaperName
    if (-not $PSCmdlet.ShouldProcess($wallpaperPath, "Set desktop wallpaper")) {
        return
    }

    $localWallpaperPath = if ($installerRoot) {
        Join-Path $installerRoot "config\$wallpaperName"
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $wallpaperPath) -Force | Out-Null
    if ($localWallpaperPath -and (Test-Path -LiteralPath $localWallpaperPath)) {
        Copy-Item -LiteralPath $localWallpaperPath -Destination $wallpaperPath -Force
    } else {
        Write-Information "Downloading desktop wallpaper..."
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/config/$wallpaperName" -OutFile $wallpaperPath -UseBasicParsing
    }

    $monitorCount = Get-DesktopMonitorCount
    # Span across two or more monitors. Fill on a single monitor.
    $wallpaperStyle = if ($monitorCount -ge 2) { "22" } else { "10" }
    $desktopSettings = "HKCU:\Control Panel\Desktop"
    Set-ItemProperty -Path $desktopSettings -Name "WallpaperStyle" -Value $wallpaperStyle
    Set-ItemProperty -Path $desktopSettings -Name "TileWallpaper" -Value "0"
    Invoke-WallpaperChange -Path $wallpaperPath
    Write-Information "Desktop wallpaper set to $wallpaperName."
}

function Invoke-WallpaperChange {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

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
    if (-not [WindowsSetup.WallpaperNativeMethods]::SystemParametersInfo(20, 0, $Path, 3)) {
        $win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw [ComponentModel.Win32Exception]::new($win32Error, "Failed to set the desktop wallpaper.")
    }
}

function Get-DesktopMonitorCount {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $count = @([System.Windows.Forms.Screen]::AllScreens).Count
        if ($count -gt 0) {
            return $count
        }
    } catch {
        Write-Information "Could not count monitors. Using one display for the wallpaper."
    }

    return 1
}

function Restart-ExplorerShell {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess("explorer", "Restart the shell")) {
        return
    }

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    Get-Process -Name "explorer" | Stop-Process -Force
    $ErrorActionPreference = $previousErrorAction

    $deadline = (Get-Date).AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 200
        $explorer = Get-Process -Name "explorer" -ErrorAction SilentlyContinue
    } while (-not $explorer -and (Get-Date) -lt $deadline)

    if (-not $explorer) {
        Start-Process -FilePath "explorer.exe"
    }

    # Hotkeys are registered after the shell window exists.
    Start-Sleep -Seconds 2
}

function Enable-TaskbarAutoHide {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3"
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Information "Taskbar settings were not found, so auto-hide was not enabled."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($path, "Automatically hide the taskbar")) {
        return
    }

    $settings = (Get-ItemProperty -LiteralPath $path -Name Settings).Settings
    # Byte 8: 0x02 = always show, 0x03 = auto-hide.
    if ($settings[8] -eq 3) {
        Write-Information "The taskbar already hides until the pointer reaches the bottom."
        return
    }

    $settings[8] = 3
    Set-ItemProperty -LiteralPath $path -Name Settings -Value $settings
    Restart-ExplorerShell
    Write-Information "The taskbar hides until the pointer reaches the bottom."
}

function Set-ExplorerPreference {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $explorerPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    if (-not $PSCmdlet.ShouldProcess($explorerPath, "Show file extensions and hidden files")) {
        return
    }

    # New-Item -Force on an existing registry key deletes its values.
    # Explorer\Advanced also denies recreating the key.
    if (-not (Test-Path -LiteralPath $explorerPath)) {
        New-Item -Path $explorerPath | Out-Null
    }
    New-ItemProperty -Path $explorerPath -Name "HideFileExt" -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $explorerPath -Name "Hidden" -PropertyType DWord -Value 1 -Force | Out-Null
    Write-Information "File Explorer shows extensions and hidden files."
    Enable-TaskbarAutoHide
}
