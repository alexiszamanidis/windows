$ErrorActionPreference = "Stop"
$InformationPreference = "Continue"

$repoRawBase = "https://raw.githubusercontent.com/alexiszamanidis/windows"
$packagesFile = if ($PSScriptRoot) {
    Join-Path $PSScriptRoot "packages.txt"
} else {
    Join-Path $env:TEMP "windows-packages.txt"
}

$knownTasks = @("DarkMode", "Wallpaper", "Explorer", "LongPaths", "Git", "Packages", "Wsl", "Font", "Terminal")
$selectedTasks = $null
# A param block would break `irm ... | iex`, so a file run takes the task list as its first argument.
if ($PSCommandPath -and $args.Count -gt 0) {
    $selectedTasks = @($args[0].Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if (-not $selectedTasks -and $env:WINDOWS_TASKS) {
    $selectedTasks = @($env:WINDOWS_TASKS.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if (-not $selectedTasks) {
    $selectedTasks = $knownTasks
}
$unknownTasks = @($selectedTasks | Where-Object { $knownTasks -notcontains $_ })
if ($unknownTasks.Count -gt 0) {
    throw "Unknown task: $($unknownTasks -join ', '). Known tasks: $($knownTasks -join ', ')."
}

function Test-SelectedTask {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    return $selectedTasks -contains $Name
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Information "Administrator permission is required. Restarting elevated..."
    if ($PSCommandPath) {
        $argumentList = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath,
            ($selectedTasks -join ",")
        )
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

$packageOptionsFile = if ($PSScriptRoot) {
    Join-Path $PSScriptRoot "packages.psd1"
} else {
    Join-Path $env:TEMP "windows-packages.psd1"
}

if (-not (Test-Path $packageOptionsFile)) {
    Write-Information "packages.psd1 not found locally. Downloading from GitHub..."
    try {
        Invoke-WebRequest -Uri "$repoRawBase/master/packages.psd1" -OutFile $packageOptionsFile -UseBasicParsing
    } catch {
        throw "packages.psd1 not found at $packageOptionsFile and download from GitHub failed."
    }
}

$packageOptions = Import-PowerShellDataFile $packageOptionsFile

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

    $monitorCount = Get-DesktopMonitorCount
    # Span across two or more monitors. Fill on a single monitor.
    $wallpaperStyle = if ($monitorCount -ge 2) { "22" } else { "10" }
    $desktopSettings = "HKCU:\Control Panel\Desktop"
    Set-ItemProperty -Path $desktopSettings -Name "WallpaperStyle" -Value $wallpaperStyle
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

function Set-ExplorerPreference {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $explorerPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    if (-not $PSCmdlet.ShouldProcess($explorerPath, "Show file extensions and hidden files")) {
        return
    }

    New-Item -Path $explorerPath -Force | Out-Null
    New-ItemProperty -Path $explorerPath -Name "HideFileExt" -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $explorerPath -Name "Hidden" -PropertyType DWord -Value 1 -Force | Out-Null
    Write-Information "File Explorer shows extensions and hidden files."
}

function Get-GitCommand {
    $gitOnPath = Get-Command git -ErrorAction SilentlyContinue
    if ($gitOnPath) {
        return $gitOnPath.Source
    }

    $gitCandidate = Join-Path $env:ProgramFiles "Git\cmd\git.exe"
    if (Test-Path -LiteralPath $gitCandidate) {
        return $gitCandidate
    }

    return $null
}

function Enable-LongPath {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess("Windows and Git", "Enable long paths")) {
        return
    }

    $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
    New-ItemProperty -Path $registryPath -Name "LongPathsEnabled" -PropertyType DWord -Value 1 -Force | Out-Null
    Write-Information "Windows long paths are enabled."

    $gitCommand = Get-GitCommand
    if (-not $gitCommand) {
        Write-Information "Git is not installed yet, so core.longpaths was not set."
        return
    }

    & $gitCommand config --global core.longpaths true
    if ($LASTEXITCODE -ne 0) {
        throw "Could not set Git core.longpaths (exit code $LASTEXITCODE)."
    }
    Write-Information "Git core.longpaths is enabled."
}

function Set-GitIdentity {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess("Git", "Set identity")) {
        return
    }

    $gitCommand = Get-GitCommand
    if (-not $gitCommand) {
        Write-Information "Git is not installed yet, so the Git identity was not set."
        return
    }

    $settings = [ordered]@{
        "user.name"           = "alexiszamanidis"
        "user.email"          = "alexiszamanidis@outlook.com"
        "pull.rebase"         = "true"
        "init.defaultBranch"  = "master"
        "fetch.prune"         = "true"
        "credential.helper"   = "manager"
    }

    foreach ($name in $settings.Keys) {
        & $gitCommand config --global $name $settings[$name]
        if ($LASTEXITCODE -ne 0) {
            throw "Could not set Git $name (exit code $LASTEXITCODE)."
        }
    }

    Write-Information "Git identity is set."
}

if (Test-SelectedTask "DarkMode") {
    Set-DarkMode
}
if (Test-SelectedTask "Wallpaper") {
    Set-DesktopWallpaper
}
if (Test-SelectedTask "Explorer") {
    Set-ExplorerPreference
}

# 0x8A15002B: package is already installed and no newer version is available.
$wingetUpdateNotApplicable = -1978335189
# 0x8A15010C: Inno Setup aborted a suppressed prompt and WinGet reports it as cancelled.
$wingetInstallCancelled = -1978334964

function Stop-PackageApplication {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$ProcessName,
        [string]$ServiceName
    )

    $target = if ($ServiceName) { $ServiceName } else { "package processes" }
    if (-not $PSCmdlet.ShouldProcess($target)) {
        return
    }

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    foreach ($name in $ProcessName) {
        Get-Process -Name $name | Stop-Process -Force
    }
    if ($ServiceName) {
        Stop-Service -Name $ServiceName -Force
    }
    $ErrorActionPreference = $previousErrorAction
}

function Install-WinGetPackage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Id,
        [hashtable]$Option
    )

    if (-not $PSCmdlet.ShouldProcess($Id)) {
        return 0
    }

    if (-not $Option) {
        $Option = @{}
    }

    $arguments = @(
        "install",
        "--id", $Id,
        "--exact",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity"
    )

    if ($Option.Source) {
        $arguments += @("--source", $Option.Source)
    }
    if ($Option.Silent) {
        $arguments += "--silent"
    }
    if ($Option.Processes -or $Option.Service) {
        # The silent installer exits 5 when it cannot close a program using its files.
        Stop-PackageApplication -ProcessName $Option.Processes -ServiceName $Option.Service
    }
    if ($Option.Custom) {
        $arguments += @("--custom", $Option.Custom)
    }

    & winget @arguments | Out-Host
    return $LASTEXITCODE
}

if (Test-SelectedTask "Packages") {
    if ($packages.Count -eq 0) {
        Write-Information "packages.txt has no package IDs yet."
    }

    foreach ($id in $packages) {
        $option = $packageOptions[$id]
        Write-Information "Installing $id"
        $exitCode = Install-WinGetPackage -Id $id -Option $option
        if ($option.RetryOnCancel -and $exitCode -eq $wingetInstallCancelled) {
            Write-Information "$id installer aborted. Closing its processes and retrying."
            $exitCode = Install-WinGetPackage -Id $id -Option $option
        }
        if ($exitCode -eq $wingetUpdateNotApplicable) {
            Write-Information "$id is already installed and up to date."
            continue
        }
        if ($exitCode -ne 0) {
            throw "WinGet failed to install $id (exit code $exitCode)."
        }
    }
}

if (Test-SelectedTask "LongPaths") {
    Enable-LongPath
}
if (Test-SelectedTask "Git") {
    Set-GitIdentity
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

function Get-PreferredWslDistroName {
    $listed = Get-WslOutput -Arguments @("--list", "--verbose")
    if ($listed.ExitCode -ne 0 -and $listed.Output -notmatch "(?i)no installed distributions") {
        return "Ubuntu"
    }

    $distros = @(Get-WslDistroFromOutput -Lines $listed.Lines)
    $exact = $distros | Where-Object { $_.Name -eq "Ubuntu" } | Select-Object -First 1
    if ($exact) {
        return $exact.Name
    }

    $versioned = $distros | Where-Object { $_.Name -like "Ubuntu*" } | Select-Object -First 1
    if ($versioned) {
        return $versioned.Name
    }

    return "Ubuntu"
}

# Windows Terminal builds each WSL profile GUID as a UUIDv5 of the distro name.
# The namespace is Terminal's own. Ubuntu resolves to {2c4de342-38b7-51cf-b940-2309a097f518}.
function Get-WslTerminalProfileGuid {
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )

    $namespace = [guid]"2bde4a90-d05f-401c-9492-e40884ead1d8"
    $namespaceBytes = $namespace.ToByteArray()
    $buffer = [System.Collections.Generic.List[byte]]::new()
    foreach ($index in 3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15) {
        $buffer.Add([byte]$namespaceBytes[$index])
    }
    foreach ($nameByte in [System.Text.Encoding]::Unicode.GetBytes($DistroName)) {
        $buffer.Add([byte]$nameByte)
    }

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha1.ComputeHash($buffer.ToArray())
    } finally {
        $sha1.Dispose()
    }

    $hash[6] = [byte](($hash[6] -band 0x0F) -bor 0x50)
    $hash[8] = [byte](($hash[8] -band 0x3F) -bor 0x80)

    $guidBytes = [System.Collections.Generic.List[byte]]::new()
    foreach ($index in 3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15) {
        $guidBytes.Add([byte]$hash[$index])
    }

    return "{" + ([guid]::new($guidBytes.ToArray())).ToString() + "}"
}

function Install-HackNerdFont {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $fontDirectory = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
    if (-not $PSCmdlet.ShouldProcess($fontDirectory, "Install Hack Nerd Font Mono")) {
        return
    }

    New-Item -ItemType Directory -Path $fontDirectory -Force | Out-Null
    $registryPath = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
    if (-not (Test-Path $registryPath)) {
        New-Item -Path $registryPath -Force | Out-Null
    }

    if (-not ([System.Management.Automation.PSTypeName]"WindowsSetup.FontNativeMethods").Type) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace WindowsSetup {
    public static class FontNativeMethods {
        [DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern int AddFontResource(string fileName);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    }
}
"@
    }

    $styles = @(
        @{ File = "HackNerdFontMono-Regular.ttf"; Name = "Hack Nerd Font Mono Regular (TrueType)" }
        @{ File = "HackNerdFontMono-Bold.ttf"; Name = "Hack Nerd Font Mono Bold (TrueType)" }
        @{ File = "HackNerdFontMono-Italic.ttf"; Name = "Hack Nerd Font Mono Italic (TrueType)" }
        @{ File = "HackNerdFontMono-BoldItalic.ttf"; Name = "Hack Nerd Font Mono Bold Italic (TrueType)" }
    )

    foreach ($style in $styles) {
        $destination = Join-Path $fontDirectory $style.File
        if (-not (Test-Path -LiteralPath $destination)) {
            $fontUri = "https://raw.githubusercontent.com/ryanoasis/nerd-fonts/master/patched-fonts/Hack/$($style.File)"
            Invoke-WebRequest -Uri $fontUri -OutFile $destination -UseBasicParsing
        }
        if ((Get-Item -LiteralPath $destination).Length -eq 0) {
            throw "Font file $destination is empty."
        }

        New-ItemProperty -Path $registryPath -Name $style.Name -PropertyType String -Value $destination -Force | Out-Null
        [void][WindowsSetup.FontNativeMethods]::AddFontResource($destination)
    }

    $broadcastResult = [IntPtr]::Zero
    [void][WindowsSetup.FontNativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 5000, [ref]$broadcastResult)
    Write-Information "Hack Nerd Font Mono installed."
}

function Get-WindowsTerminalSettingsPath {
    $packagesRoot = Join-Path $env:LOCALAPPDATA "Packages"
    $knownFamily = Join-Path $packagesRoot "Microsoft.WindowsTerminal_8wekyb3d8bbwe"
    if (Test-Path $knownFamily) {
        return Join-Path $knownFamily "LocalState\settings.json"
    }

    if (Test-Path $packagesRoot) {
        $family = Get-ChildItem -Path $packagesRoot -Directory -Filter "Microsoft.WindowsTerminal_*" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike "*Preview*" } |
            Select-Object -First 1
        if ($family) {
            return (Join-Path $family.FullName "LocalState\settings.json")
        }
    }

    return Join-Path $knownFamily "LocalState\settings.json"
}

function Set-WindowsTerminalSetting {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $settingsPath = Get-WindowsTerminalSettingsPath
    if (-not $PSCmdlet.ShouldProcess($settingsPath, "Write Windows Terminal settings")) {
        return
    }

    $templatePath = if ($PSScriptRoot) {
        Join-Path $PSScriptRoot "terminal-settings.json"
    }
    if (-not ($templatePath -and (Test-Path -LiteralPath $templatePath))) {
        $templatePath = Join-Path $env:TEMP "windows-terminal-settings.json"
        Invoke-WebRequest -Uri "$repoRawBase/master/terminal-settings.json" -OutFile $templatePath -UseBasicParsing
    }

    $distroName = Get-PreferredWslDistroName
    $profileGuid = Get-WslTerminalProfileGuid -DistroName $distroName
    $settings = [System.IO.File]::ReadAllText($templatePath)
    $settings = $settings.Replace("__WSL_DISTRO__", $distroName).Replace("__WSL_GUID__", $profileGuid.Trim("{}"))
    if ($settings.Contains("__WSL_")) {
        throw "Windows Terminal settings still contain an unreplaced placeholder."
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $settingsPath) -Force | Out-Null
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($settingsPath, $settings, $utf8)
    Write-Information "Windows Terminal settings written for $distroName."
}

if (Test-SelectedTask "Wsl") {
    Install-WslUbuntu
}
if (Test-SelectedTask "Font") {
    Install-HackNerdFont
}
if (Test-SelectedTask "Terminal") {
    Set-WindowsTerminalSetting
}
