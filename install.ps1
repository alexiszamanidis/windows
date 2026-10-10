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

function Get-WslOutput {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    # wsl.exe writes UTF-16 from Windows PowerShell and treats stderr as an error record.
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lines = @(& wsl @Arguments 2>&1 | ForEach-Object { "$_" -replace "`0", "" })
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }

    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($lines -join [Environment]::NewLine)
        Lines    = $lines
    }
}

function Test-WslRebootRequired {
    param(
        [Parameter(Mandatory)]
        $Result
    )

    return $Result.Output -match "(?i)\b(reboot|restart)"
}

function Test-WslPlatformMissing {
    param(
        [Parameter(Mandatory)]
        $Result
    )

    return $Result.Output -match "(?i)not installed|WSL_E_WSL_OPTIONAL_COMPONENT_REQUIRED|0x8007019e"
}

function Get-WslDistroFromOutput {
    param([string[]]$Lines)

    $distros = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $Lines) {
        $clean = $line.Trim()
        if ($clean -match '^\*?\s*(\S+)\s+\S+\s+(\d+)\s*$') {
            $distro = [pscustomobject]@{
                Name    = $Matches[1]
                Version = $Matches[2]
            }
            [void]$distros.Add($distro)
        }
    }
    Write-Output -InputObject $distros -NoEnumerate
}

function Get-WslDistroList {
    $listed = Get-WslOutput -Arguments @("--list", "--verbose")
    if ($listed.ExitCode -eq 0) {
        Write-Output -InputObject (Get-WslDistroFromOutput -Lines $listed.Lines) -NoEnumerate
        return
    }

    if (Test-WslRebootRequired $listed) {
        throw "WSL_REBOOT_REQUIRED"
    }

    # A fresh WSL install reports this instead of an empty table.
    if ($listed.Output -match "(?i)no installed distributions") {
        Write-Output -InputObject ([System.Collections.Generic.List[object]]::new()) -NoEnumerate
        return
    }

    if (-not (Test-WslPlatformMissing $listed)) {
        throw "Could not list WSL distros (exit code $($listed.ExitCode)). $($listed.Output)"
    }

    Write-Information "Installing the Windows Subsystem for Linux."
    $platform = Get-WslOutput -Arguments @("--install", "--no-distribution")
    if (Test-WslRebootRequired $platform) {
        throw "WSL_REBOOT_REQUIRED"
    }
    if ($platform.ExitCode -ne 0) {
        throw "WSL installation failed (exit code $($platform.ExitCode)). $($platform.Output)"
    }

    $listed = Get-WslOutput -Arguments @("--list", "--verbose")
    if ($listed.ExitCode -ne 0) {
        if (Test-WslRebootRequired $listed) {
            throw "WSL_REBOOT_REQUIRED"
        }
        if ($listed.Output -match "(?i)no installed distributions") {
            Write-Output -InputObject ([System.Collections.Generic.List[object]]::new()) -NoEnumerate
            return
        }
        throw "Could not list WSL distros (exit code $($listed.ExitCode)). $($listed.Output)"
    }

    Write-Output -InputObject (Get-WslDistroFromOutput -Lines $listed.Lines) -NoEnumerate
}

function Install-WslUbuntu {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $distroName = "Ubuntu"
    if (-not $PSCmdlet.ShouldProcess($distroName, "Install WSL2 and Ubuntu")) {
        return
    }

    try {
        $distros = Get-WslDistroList
        $defaultVersion = Get-WslOutput -Arguments @("--set-default-version", "2")
        if (Test-WslRebootRequired $defaultVersion) {
            throw "WSL_REBOOT_REQUIRED"
        }
        if ($defaultVersion.ExitCode -ne 0) {
            throw "Could not set WSL2 as the default version (exit code $($defaultVersion.ExitCode)). $($defaultVersion.Output)"
        }

        $existing = $distros | Where-Object { $_.Name -eq $distroName } | Select-Object -First 1
        if (-not $existing) {
            $existing = $distros | Where-Object { $_.Name -like "Ubuntu-*" } | Select-Object -First 1
        }

        if (-not $existing) {
            Write-Information "Installing Ubuntu for WSL."
            $installed = Get-WslOutput -Arguments @("--install", "--distribution", $distroName, "--no-launch", "--web-download")
            if (Test-WslRebootRequired $installed) {
                throw "WSL_REBOOT_REQUIRED"
            }
            if ($installed.ExitCode -ne 0) {
                throw "Ubuntu installation failed (exit code $($installed.ExitCode)). $($installed.Output)"
            }
            $existing = [pscustomobject]@{
                Name    = $distroName
                Version = "2"
            }
        } else {
            Write-Information "$($existing.Name) is already installed."
        }

        if ($existing.Version -ne "2") {
            Write-Information "Converting $($existing.Name) to WSL2."
            $converted = Get-WslOutput -Arguments @("--set-version", $existing.Name, "2")
            if (Test-WslRebootRequired $converted) {
                throw "WSL_REBOOT_REQUIRED"
            }
            if ($converted.ExitCode -ne 0) {
                throw "Could not convert $($existing.Name) to WSL2 (exit code $($converted.ExitCode)). $($converted.Output)"
            }
        }

        $defaultDistro = Get-WslOutput -Arguments @("--set-default", $existing.Name)
        if ($defaultDistro.ExitCode -ne 0) {
            throw "Could not set $($existing.Name) as the default WSL distro (exit code $($defaultDistro.ExitCode)). $($defaultDistro.Output)"
        }

        Write-Information "$($existing.Name) is ready on WSL2."
        Write-Information "Open Ubuntu and create your Linux user if this is the first launch."
        Write-Information "Then install Linux packages with the Ansible repo. This script stops before that."
        Write-Information "git clone https://github.com/alexiszamanidis/ansible.git ~/ansible && cd ~/ansible && git remote set-url origin git@github.com:alexiszamanidis/ansible.git && ./install"
    } catch {
        if ($_.Exception.Message -eq "WSL_REBOOT_REQUIRED") {
            Write-Information "Restart Windows, then run this installer again to install Ubuntu."
            return
        }
        throw
    }
}

Install-WslUbuntu
