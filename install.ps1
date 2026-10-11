$ErrorActionPreference = "Stop"
$InformationPreference = "Continue"

$repoRawBase = "https://raw.githubusercontent.com/alexiszamanidis/windows"
$repoRef = "HEAD"
$installerRoot = $PSScriptRoot
$packagesFile = if ($PSScriptRoot) {
    Join-Path $PSScriptRoot "packages.txt"
} else {
    Join-Path $env:TEMP "windows-packages.txt"
}

$knownTasks = @("DarkMode", "Wallpaper", "Explorer", "LongPaths", "Git", "Packages", "FlowLauncher", "GlazeWM", "InputLeap", "Wsl", "Font", "Terminal")
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
        $argumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "irm $repoRawBase/$repoRef/install.ps1 | iex")
    }
    Start-Process -FilePath "powershell" -Verb RunAs -ArgumentList $argumentList | Out-Null
    exit 0
}

if (-not (Test-Path $packagesFile)) {
    Write-Information "packages.txt not found locally. Downloading from GitHub..."
    try {
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/packages.txt" -OutFile $packagesFile -UseBasicParsing
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
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/packages.psd1" -OutFile $packageOptionsFile -UseBasicParsing
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
        Join-Path $installerRoot $wallpaperName
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $wallpaperPath) -Force | Out-Null
    if ($localWallpaperPath -and (Test-Path -LiteralPath $localWallpaperPath)) {
        Copy-Item -LiteralPath $localWallpaperPath -Destination $wallpaperPath -Force
    } else {
        Write-Information "Downloading desktop wallpaper..."
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/$wallpaperName" -OutFile $wallpaperPath -UseBasicParsing
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

    New-Item -Path $explorerPath -Force | Out-Null
    New-ItemProperty -Path $explorerPath -Name "HideFileExt" -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $explorerPath -Name "Hidden" -PropertyType DWord -Value 1 -Force | Out-Null
    Write-Information "File Explorer shows extensions and hidden files."
    Enable-TaskbarAutoHide
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

function Get-InputLeapServer {
    $candidates = @(
        (Join-Path $env:ProgramFiles "Input Leap\input-leaps.exe")
    )
    $programFilesX86 = ${env:ProgramFiles(x86)}
    if ($programFilesX86) {
        $candidates += Join-Path $programFilesX86 "Input Leap\input-leaps.exe"
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Set-InputLeapLayout {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $profileDir = Join-Path $env:LOCALAPPDATA "InputLeap"
    $configPath = Join-Path $profileDir "input-leap.sgc"
    if (-not $PSCmdlet.ShouldProcess($configPath, "Deploy Input Leap layout")) {
        return
    }

    $sourcePath = if ($PSScriptRoot) {
        Join-Path $PSScriptRoot "input-leap.sgc"
    } else {
        $null
    }
    if (-not ($sourcePath -and (Test-Path -LiteralPath $sourcePath))) {
        $sourcePath = Join-Path $env:TEMP "windows-input-leap.sgc"
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/input-leap.sgc" -OutFile $sourcePath -UseBasicParsing
    }

    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $configPath -Force
    Write-Information "Input Leap layout written."

    $serverExe = Get-InputLeapServer
    if (-not $serverExe) {
        Write-Information "Input Leap is not installed yet, so it was not added to startup."
        return
    }

    $runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $runValue = "`"$serverExe`" --config `"$configPath`" --name Desktop --disable-crypto"
    New-ItemProperty -Path $runPath -Name "InputLeap" -PropertyType String -Value $runValue -Force | Out-Null
    Write-Information "Input Leap server starts at login."

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    Get-Process -Name "input-leaps" | Stop-Process -Force
    $ErrorActionPreference = $previousErrorAction
    Start-Process -FilePath $serverExe -ArgumentList @(
        "--config", $configPath,
        "--name", "Desktop",
        "--disable-crypto"
    )
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

    return Invoke-WinGet -Argument $arguments
}

function Invoke-WinGet {
    param(
        [string[]]$Argument
    )

    & winget @Argument | Out-Host
    return $LASTEXITCODE
}

function Install-RequestedPackage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Id,
        [hashtable]$Option
    )

    if (-not $PSCmdlet.ShouldProcess($Id)) {
        return
    }

    Write-Information "Installing $Id"
    $exitCode = Install-WinGetPackage -Id $Id -Option $Option
    if ($Option.RetryOnCancel -and $exitCode -eq $wingetInstallCancelled) {
        Write-Information "$Id installer aborted. Closing its processes and retrying."
        $exitCode = Install-WinGetPackage -Id $Id -Option $Option
    }
    if ($exitCode -eq $wingetUpdateNotApplicable) {
        Write-Information "$Id is already installed and up to date."
        return
    }
    if ($exitCode -ne 0) {
        throw "WinGet failed to install $Id (exit code $exitCode)."
    }
}

if (Test-SelectedTask "Packages") {
    if ($packages.Count -eq 0) {
        Write-Information "packages.txt has no package IDs yet."
    }

    foreach ($id in $packages) {
        Install-RequestedPackage -Id $id -Option $packageOptions[$id]
    }
}

function Get-FlowLauncherSettingsPath {
    return Join-Path (Join-Path $env:APPDATA "FlowLauncher\Settings") "Settings.json"
}

function Get-FlowLauncherExecutable {
    $root = Join-Path $env:LOCALAPPDATA "FlowLauncher"
    $stub = Join-Path $root "Flow.Launcher.exe"
    if (Test-Path -LiteralPath $stub) {
        return $stub
    }

    if (-not (Test-Path -LiteralPath $root)) {
        return $null
    }

    $found = Get-ChildItem -LiteralPath $root -Filter "Flow.Launcher.exe" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) {
        return $found.FullName
    }

    return $null
}

function Stop-FlowLauncher {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess("Flow.Launcher", "Stop")) {
        return
    }

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    Get-Process -Name "Flow.Launcher" | Stop-Process -Force
    $ErrorActionPreference = $previousErrorAction
}

function Disable-WindowsProjectHotkey {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    )

    # Explorer reads this when the shell starts. Upper-case P is Win+P. Lower-case p is F1.
    if (-not $PSCmdlet.ShouldProcess($Path, "Disable the Windows project shortcut")) {
        return
    }

    # New-Item -Force on an existing registry key deletes its values.
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path | Out-Null
    }

    $existing = ""
    try {
        $existing = [string](Get-ItemPropertyValue -LiteralPath $Path -Name "DisabledHotkeys")
    } catch {
        $existing = ""
    }
    if ($existing.IndexOf("P", [System.StringComparison]::Ordinal) -lt 0) {
        $existing += "P"
    }

    New-ItemProperty -LiteralPath $Path -Name "DisabledHotkeys" -PropertyType String -Value $existing -Force | Out-Null
    Write-Information "Windows project shortcut is disabled."
}

function Get-JsonWithProperty {
    param(
        [string]$Json,
        [string]$Name,
        [string]$EncodedValue
    )

    $property = '"' + $Name + '": ' + $EncodedValue
    $stringPattern = '"' + [regex]::Escape($Name) + '"\s*:\s*"(?:\\.|[^"\\])*"'
    $booleanPattern = '"' + [regex]::Escape($Name) + '"\s*:\s*(?:true|false)'
    $matchPattern = if ($EncodedValue.StartsWith('"')) { $stringPattern } else { $booleanPattern }
    if ([regex]::IsMatch($Json, $matchPattern)) {
        $regex = [regex]::new($matchPattern)
        return $regex.Replace($Json, $property, 1)
    }

    $index = $Json.IndexOf("{")
    if ($index -lt 0) {
        return "{`r`n    $property`r`n}`r`n"
    }

    $prefix = $Json.Substring(0, $index + 1)
    $suffix = $Json.Substring($index + 1)
    if ($suffix -match '^\s*\}') {
        return $prefix + "`r`n    $property`r`n}`r`n"
    }

    return $prefix + "`r`n    $property," + $suffix
}

function Set-FlowLauncherSetting {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $settingsPath = Get-FlowLauncherSettingsPath
    if (-not $PSCmdlet.ShouldProcess($settingsPath, "Set the Flow Launcher hotkey")) {
        return
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $settingsPath) -Force | Out-Null
    if (Test-Path -LiteralPath $settingsPath) {
        $json = [System.IO.File]::ReadAllText($settingsPath)
    } else {
        $json = "{}"
    }

    $json = Get-JsonWithProperty -Json $json -Name "Hotkey" -EncodedValue '"Win + P"'
    $json = Get-JsonWithProperty -Json $json -Name "StartFlowLauncherOnSystemStartup" -EncodedValue "true"
    $json = Add-FlowLauncherWindowHotkey -Json $json
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($settingsPath, $json, $utf8)
    Write-Information "Flow Launcher hotkey is Win+P. Win+Shift+P searches open windows."
}

function Add-FlowLauncherWindowHotkey {
    param(
        [string]$Json
    )

    # Used when Flow can register hotkeys. The capture helper removes it and handles Win+Shift+P itself.
    $hotkey = '"Hotkey": "Win + Shift + P"'
    $escapedHotkey = '"Hotkey": "Win \u002B Shift \u002B P"'
    if ($Json.Contains($hotkey) -or $Json.Contains($escapedHotkey)) {
        return $Json
    }

    $entry = "{`r`n      `"Hotkey`": `"Win + Shift + P`",`r`n      `"ActionKeyword`": `"w `"`r`n    }"
    $name = "CustomPluginHotkeys"
    $emptyPattern = '"' + [regex]::Escape($name) + '"\s*:\s*\[\s*\]'
    if ([regex]::IsMatch($Json, $emptyPattern)) {
        $replacement = '"' + $name + '": [' + "`r`n    " + $entry + "`r`n  ]"
        return ([regex]::new($emptyPattern)).Replace($Json, $replacement, 1)
    }

    $startPattern = '"' + [regex]::Escape($name) + '"\s*:\s*\['
    $start = [regex]::Match($Json, $startPattern)
    if ($start.Success) {
        return $Json.Insert($start.Index + $start.Length, "`r`n    $entry,")
    }

    $encoded = "[`r`n    $entry`r`n  ]"
    return Get-JsonWithProperty -Json $Json -Name $name -EncodedValue $encoded
}

function Remove-FlowLauncherWindowHotkey {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Json
    )

    if (-not $PSCmdlet.ShouldProcess("Flow Launcher settings", "Remove the Win+Shift+P hotkey")) {
        return $Json
    }

    $markers = @(
        '"Hotkey": "Win + Shift + P"',
        '"Hotkey": "Win \u002B Shift \u002B P"'
    )
    $marker = $null
    foreach ($candidate in $markers) {
        if ($Json.Contains($candidate)) {
            $marker = $candidate
            break
        }
    }
    if (-not $marker) {
        return $Json
    }

    $hotkeyAt = $Json.IndexOf($marker)
    $objectStart = $Json.LastIndexOf("{", $hotkeyAt)
    $objectEnd = $Json.IndexOf("}", $hotkeyAt)
    if ($objectStart -lt 0 -or $objectEnd -lt 0) {
        return $Json
    }

    $before = $Json.Substring(0, $objectStart)
    $after = $Json.Substring($objectEnd + 1)
    if ($after -match '^\s*,') {
        $after = [regex]::Replace($after, '^\s*,', '', 1)
    } elseif ($before -match ',\s*$') {
        $before = [regex]::Replace($before, ',\s*$', '')
    }

    $updated = $before + $after
    return [regex]::Replace($updated, '"CustomPluginHotkeys"\s*:\s*\[\s*\]', '"CustomPluginHotkeys": []', 1)
}

function Set-FlowLauncherWindowWalkerKeyword {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ManifestPath
    )

    if (-not $PSCmdlet.ShouldProcess($ManifestPath, "Search open windows with w")) {
        return
    }

    $json = [System.IO.File]::ReadAllText($ManifestPath)
    $arrayPattern = '"ActionKeywords"\s*:\s*\[[^\]]*\]'
    if ([regex]::IsMatch($json, $arrayPattern)) {
        $json = ([regex]::new($arrayPattern)).Replace($json, '"ActionKeywords": ["w"]', 1)
    } else {
        $json = Get-JsonWithProperty -Json $json -Name "ActionKeyword" -EncodedValue '"w"'
    }

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($ManifestPath, $json, $utf8)
}

function Get-FlowLauncherWindowWalkerSettingsPath {
    $plugins = Join-Path (Join-Path $env:APPDATA "FlowLauncher\Settings") "Plugins"
    return Join-Path (Join-Path $plugins "Flow.Plugin.WindowWalker") "Settings.json"
}

function Set-FlowLauncherWindowWalkerSearch {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $settingsPath = Get-FlowLauncherWindowWalkerSettingsPath
    if (-not $PSCmdlet.ShouldProcess($settingsPath, "Search windows on every workspace")) {
        return
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $settingsPath) -Force | Out-Null
    if (Test-Path -LiteralPath $settingsPath) {
        $json = [System.IO.File]::ReadAllText($settingsPath)
    } else {
        $json = "{}"
    }

    # GlazeWM cloaks windows on other workspaces. Window Walker skips those unless this is on.
    $json = Get-JsonWithProperty -Json $json -Name "SearchCloakedWindows" -EncodedValue "true"
    $json = Get-JsonWithProperty -Json $json -Name "SearchWindowsAcrossAllVDesktop" -EncodedValue "true"
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($settingsPath, $json, $utf8)
}

function Update-FlowLauncherWindowWalkerTaskList {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $dll = Join-Path (Join-Path (Join-Path $env:APPDATA "FlowLauncher") "Plugins") "Flow.Plugin.WindowWalker\Flow.Plugin.WindowWalker.dll"
    if (-not (Test-Path -LiteralPath $dll)) {
        return
    }
    if (-not $PSCmdlet.ShouldProcess($dll, "List windows hidden from the taskbar")) {
        return
    }

    $flowRoot = Join-Path $env:LOCALAPPDATA "FlowLauncher"
    $cecil = $null
    if (Test-Path -LiteralPath $flowRoot) {
        $cecil = Get-ChildItem -LiteralPath $flowRoot -Filter "Mono.Cecil.dll" -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if (-not $cecil) {
        Write-Information "Flow Launcher is not installed yet, so windows hidden from the taskbar were left out of the search."
        return
    }

    if (-not ([System.Management.Automation.PSTypeName]"Mono.Cecil.AssemblyDefinition").Type) {
        Add-Type -Path $cecil.FullName
    }

    $parameters = New-Object Mono.Cecil.ReaderParameters
    $parameters.ReadSymbols = $false
    $assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($dll, $parameters)
    $patched = "$dll.patched"
    try {
        $window = $assembly.MainModule.Types | Where-Object { $_.FullName -eq "Flow.Plugin.WindowWalker.Components.Window" }
        $getter = $window.Methods | Where-Object { $_.Name -eq "get_TaskListDeleted" }
        $instructions = @($getter.Body.Instructions)
        $alreadyPatched = $instructions.Count -eq 2 -and
            $instructions[0].OpCode.ToString() -eq "ldc.i4.0" -and
            $instructions[1].OpCode.ToString() -eq "ret"
        if ($alreadyPatched) {
            return
        }

        $processor = $getter.Body.GetILProcessor()
        foreach ($instruction in $instructions) {
            $processor.Remove($instruction)
        }
        $processor.Append($processor.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
        $processor.Append($processor.Create([Mono.Cecil.Cil.OpCodes]::Ret))

        $writer = New-Object Mono.Cecil.WriterParameters
        $writer.WriteSymbols = $false
        $assembly.Write($patched, $writer)
    } finally {
        if ($assembly -and ($assembly -is [System.IDisposable])) {
            $assembly.Dispose()
        }
    }

    Move-Item -LiteralPath $patched -Destination $dll -Force
}

function Install-FlowLauncherWindowWalker {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $destination = Join-Path (Join-Path (Join-Path $env:APPDATA "FlowLauncher") "Plugins") "Flow.Plugin.WindowWalker"
    if (-not $PSCmdlet.ShouldProcess($destination, "Install Window Walker")) {
        return
    }

    $dll = Join-Path $destination "Flow.Plugin.WindowWalker.dll"
    if (-not (Test-Path -LiteralPath $dll)) {
        $pluginsRoot = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $pluginsRoot -Force | Out-Null
        $zip = Join-Path ([System.IO.Path]::GetTempPath()) "WindowWalker-3.1.0.zip"
        Invoke-WebRequest -Uri "https://github.com/taooceros/Flow.Plugin.WindowWalker/releases/download/v3.1.0/WindowWalker-3.1.0.zip" -OutFile $zip -UseBasicParsing
        $extract = Join-Path ([System.IO.Path]::GetTempPath()) "WindowWalker-3.1.0"
        if (Test-Path -LiteralPath $extract) {
            Remove-Item -LiteralPath $extract -Recurse -Force
        }
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        $manifest = Get-ChildItem -LiteralPath $extract -Filter "plugin.json" -Recurse | Select-Object -First 1
        if (-not $manifest) {
            throw "Window Walker archive does not contain plugin.json."
        }
        if (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $destination -Recurse -Force
        }
        Copy-Item -LiteralPath $manifest.Directory.FullName -Destination $destination -Recurse
    }

    Set-FlowLauncherWindowWalkerKeyword -ManifestPath (Join-Path $destination "plugin.json")
    Set-FlowLauncherWindowWalkerSearch
    # GlazeWM removes other workspaces from the taskbar. Window Walker treats that as "not a window".
    Update-FlowLauncherWindowWalkerTaskList
}

function Test-FlowLauncherHotkeyAvailable {
    if (-not ([System.Management.Automation.PSTypeName]"WindowsSetup.HotkeyNativeMethods").Type) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace WindowsSetup {
    public static class HotkeyNativeMethods {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UnregisterHotKey(IntPtr window, int id);
    }
}
"@
    }

    # MOD_WIN is 0x0008. VK_P is 0x50. This is the registration Flow Launcher attempts.
    $hotkeyId = 0x5A11
    $registered = [WindowsSetup.HotkeyNativeMethods]::RegisterHotKey([IntPtr]::Zero, $hotkeyId, 0x0008, 0x50)
    if ($registered) {
        [void][WindowsSetup.HotkeyNativeMethods]::UnregisterHotKey([IntPtr]::Zero, $hotkeyId)
    }

    return [bool]$registered
}

function Get-FlowLauncherHotkeyScriptPath {
    return Join-Path (Join-Path $env:APPDATA "WindowsSetup") "flow-launcher-hotkey.ps1"
}

function Stop-FlowLauncherHotkeyCapture {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess("FlowLauncherWinP", "Stop")) {
        return
    }

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -like "*flow-launcher-hotkey.ps1*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    $ErrorActionPreference = $previousErrorAction
}

function Install-FlowLauncherHotkeyCapture {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $destination = Get-FlowLauncherHotkeyScriptPath
    if (-not $PSCmdlet.ShouldProcess($destination, "Capture Win+P for Flow Launcher")) {
        return
    }

    $source = if ($installerRoot) {
        Join-Path $installerRoot "flow-launcher-hotkey.ps1"
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    if ($source -and (Test-Path -LiteralPath $source)) {
        Copy-Item -LiteralPath $source -Destination $destination -Force
    } else {
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/flow-launcher-hotkey.ps1" -OutFile $destination -UseBasicParsing
    }

    $runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    if (-not (Test-Path -LiteralPath $runPath)) {
        New-Item -Path $runPath | Out-Null
    }
    $runValue = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$destination`""
    New-ItemProperty -Path $runPath -Name "FlowLauncherWinP" -PropertyType String -Value $runValue -Force | Out-Null
    Stop-FlowLauncherHotkeyCapture
    # Flow cannot register Win+Shift+P while another window owns it, and it reports that on every launch.
    Clear-FlowLauncherWindowHotkey
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
        "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", $destination
    )
    Write-Information "Win+P opens Flow Launcher when Windows keeps the project shortcut. Win+Shift+P searches open windows."
}

function Clear-FlowLauncherWindowHotkey {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $settingsPath = Get-FlowLauncherSettingsPath
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        return
    }
    if (-not $PSCmdlet.ShouldProcess($settingsPath, "Leave Win+Shift+P to the capture helper")) {
        return
    }

    $json = [System.IO.File]::ReadAllText($settingsPath)
    $updated = Remove-FlowLauncherWindowHotkey -Json $json
    if ($updated -eq $json) {
        return
    }

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($settingsPath, $updated, $utf8)
}

function Remove-FlowLauncherHotkeyCapture {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    if (-not $PSCmdlet.ShouldProcess($runPath, "Remove the Win+P capture helper")) {
        return
    }

    Remove-ItemProperty -Path $runPath -Name "FlowLauncherWinP" -ErrorAction SilentlyContinue
    Stop-FlowLauncherHotkeyCapture
}

function Start-FlowLauncher {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $executable = Get-FlowLauncherExecutable
    if (-not $executable) {
        Write-Information "Flow Launcher is not installed yet, so it was not started."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($executable, "Start")) {
        return
    }

    Start-Process -FilePath $executable
    Write-Information "Flow Launcher starts at login."
}

function Set-FlowLauncherHotkey {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess("Flow Launcher", "Use Win+P")) {
        return
    }

    Stop-FlowLauncher
    Disable-WindowsProjectHotkey
    Restart-ExplorerShell
    Set-FlowLauncherSetting
    Install-FlowLauncherWindowWalker
    # Flow registers Win+P with RegisterHotKey. When Windows still owns that shortcut, registration fails
    # and Flow reports it on every launch, so a low-level hook opens Flow instead.
    if (Test-FlowLauncherHotkeyAvailable) {
        Remove-FlowLauncherHotkeyCapture
    } else {
        Install-FlowLauncherHotkeyCapture
    }

    Start-FlowLauncher
}

if (Test-SelectedTask "FlowLauncher") {
    Set-FlowLauncherHotkey
}

function Get-GlazeWmConfigPath {
    return Join-Path (Join-Path $env:USERPROFILE ".glzr\glazewm") "config.yaml"
}

function Get-GlazeWmExecutable {
    $candidates = @(
        (Join-Path $env:ProgramFiles "glzr.io\GlazeWM\glazewm.exe")
        (Join-Path $env:ProgramFiles "glzr.io\glazewm.exe")
    )
    $programFilesX86 = ${env:ProgramFiles(x86)}
    if ($programFilesX86) {
        $candidates += Join-Path $programFilesX86 "glzr.io\GlazeWM\glazewm.exe"
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-GlazeWmCli {
    $executable = Get-GlazeWmExecutable
    if (-not $executable) {
        return $null
    }

    $cli = Join-Path (Join-Path (Split-Path -Parent $executable) "cli") "glazewm.exe"
    if (Test-Path -LiteralPath $cli) {
        return $cli
    }

    return $null
}

function Test-GlazeWmRunning {
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $running = [bool](Get-Process -Name "glazewm")
    $ErrorActionPreference = $previousErrorAction
    return $running
}

function Install-RepoFile {
    param(
        [Parameter(Mandatory)]
        [string]$Source,
        [Parameter(Mandatory)]
        [string]$Destination
    )

    $sourceFull = (Resolve-Path -LiteralPath $Source).Path
    $root = if ($installerRoot -and (Test-Path -LiteralPath $installerRoot)) {
        (Resolve-Path -LiteralPath $installerRoot).Path
    } else {
        $null
    }
    $rootPrefix = if ($root) { $root.TrimEnd('\') + '\' } else { $null }
    # A checkout has a stable path, so the deployed file can point at it.
    # A downloaded copy lives in TEMP and is replaced on the next run, so that install stays a copy.
    $link = $rootPrefix -and $sourceFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)

    if ($link) {
        # Create the link beside the current file so a privilege failure leaves the existing config in place.
        $linkPath = "$Destination.link-new"
        if (Test-Path -LiteralPath $linkPath) {
            Remove-Item -LiteralPath $linkPath -Force
        }
        try {
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $sourceFull | Out-Null
        } catch {
            if (Test-Path -LiteralPath $linkPath) {
                Remove-Item -LiteralPath $linkPath -Force
            }
            throw
        }
        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Force
        }
        Move-Item -LiteralPath $linkPath -Destination $Destination
        return
    }

    Copy-Item -LiteralPath $sourceFull -Destination $Destination -Force
}

function Install-GlazeWmConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $configPath = Get-GlazeWmConfigPath
    if (-not $PSCmdlet.ShouldProcess($configPath, "Deploy GlazeWM config")) {
        return
    }

    $configDirectory = Split-Path -Parent $configPath
    $sourcePath = if ($installerRoot) {
        Join-Path $installerRoot "glazewm.yaml"
    } else {
        $null
    }
    if (-not ($sourcePath -and (Test-Path -LiteralPath $sourcePath))) {
        $sourcePath = Join-Path $env:TEMP "windows-glazewm.yaml"
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/glazewm.yaml" -OutFile $sourcePath -UseBasicParsing
    }

    $chromeStartupSource = if ($installerRoot) {
        Join-Path $installerRoot "chrome-startup.ps1"
    } else {
        $null
    }
    if (-not ($chromeStartupSource -and (Test-Path -LiteralPath $chromeStartupSource))) {
        $chromeStartupSource = Join-Path $env:TEMP "windows-chrome-startup.ps1"
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/chrome-startup.ps1" -OutFile $chromeStartupSource -UseBasicParsing
    }

    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    Install-RepoFile -Source $sourcePath -Destination $configPath
    Install-RepoFile -Source $chromeStartupSource -Destination (Join-Path $configDirectory "chrome-startup.ps1")
    Write-Information "GlazeWM config installed."
}

function Enable-GlazeWmStartup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$RunPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
        [string]$Executable = $(Get-GlazeWmExecutable)
    )

    if (-not $Executable) {
        return
    }

    if (-not $PSCmdlet.ShouldProcess($RunPath, "Start GlazeWM at login")) {
        return
    }

    if (-not (Test-Path -LiteralPath $RunPath)) {
        New-Item -Path $RunPath -Force | Out-Null
    }

    # Same value the GlazeWM tray writes. Explorer can launch this uiAccess executable.
    $runValue = "`"$Executable`""
    New-ItemProperty -Path $RunPath -Name "GlazeWM" -PropertyType String -Value $runValue -Force | Out-Null
    Write-Information "GlazeWM starts at login."
}

function Invoke-GlazeWmReload {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $cli = Get-GlazeWmCli
    if (-not $cli) {
        Write-Information "GlazeWM is running. Reload the config with Win+Shift+C."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($cli, "Reload GlazeWM config")) {
        return
    }

    & $cli command wm-reload-config | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Could not reload GlazeWM (exit code $LASTEXITCODE)."
    }

    Write-Information "GlazeWM config reloaded."
}

function Start-GlazeWmProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Executable
    )

    if (-not $PSCmdlet.ShouldProcess($Executable, "Start")) {
        return
    }

    # uiAccess programs cannot be created directly. cmd start is the path the GlazeWM CLI uses.
    # One argument string, because Windows PowerShell mishandles quoted items in an argument array.
    Start-Process -FilePath "cmd.exe" -WindowStyle Hidden -ArgumentList "/c start `"`" `"$Executable`""
}

function Get-ZebarConfigDirectory {
    return Join-Path $env:USERPROFILE ".glzr\zebar"
}

function Get-ZebarExecutable {
    $candidates = @(
        (Join-Path $env:ProgramFiles "glzr.io\Zebar\zebar.exe")
        (Join-Path $env:ProgramFiles "glzr.io\zebar.exe")
    )
    $programFilesX86 = ${env:ProgramFiles(x86)}
    if ($programFilesX86) {
        $candidates += Join-Path $programFilesX86 "glzr.io\Zebar\zebar.exe"
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $command = Get-Command -Name "zebar" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return $command.Source
    }

    return $null
}

function Add-ZebarStartupConfig {
    param(
        [string]$Json
    )

    if ($Json -match '"pack"\s*:\s*"workspaces"') {
        return $Json
    }

    $entry = '{"pack": "workspaces", "widget": "bar", "preset": "default"}'
    $match = [regex]::new('"startupConfigs"\s*:\s*\[').Match($Json)
    if (-not $match.Success) {
        return "{`r`n    `"startupConfigs`": [$entry]`r`n}`r`n"
    }

    $tail = $Json.Substring($match.Index + $match.Length).TrimStart()
    $insertion = if ($tail.StartsWith("]")) { $match.Value + $entry } else { $match.Value + $entry + "," }
    return $Json.Substring(0, $match.Index) + $insertion + $Json.Substring($match.Index + $match.Length)
}

function Install-ZebarWorkspaceBar {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $directory = Get-ZebarConfigDirectory
    $packDirectory = Join-Path $directory "workspaces"
    if (-not $PSCmdlet.ShouldProcess($packDirectory, "Install the workspace bar")) {
        return
    }

    $sourceDirectory = if ($installerRoot) {
        Join-Path $installerRoot "zebar"
    } else {
        $null
    }
    if (-not ($sourceDirectory -and (Test-Path -LiteralPath (Join-Path $sourceDirectory "zpack.json")))) {
        $sourceDirectory = Join-Path $env:TEMP "windows-zebar"
        New-Item -ItemType Directory -Path $sourceDirectory -Force | Out-Null
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/zebar/zpack.json" -OutFile (Join-Path $sourceDirectory "zpack.json") -UseBasicParsing
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/zebar/index.html" -OutFile (Join-Path $sourceDirectory "index.html") -UseBasicParsing
    }

    New-Item -ItemType Directory -Path $packDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceDirectory "zpack.json") -Destination (Join-Path $packDirectory "zpack.json") -Force
    Copy-Item -LiteralPath (Join-Path $sourceDirectory "index.html") -Destination (Join-Path $packDirectory "index.html") -Force

    $settingsPath = Join-Path $directory "settings.json"
    if (Test-Path -LiteralPath $settingsPath) {
        $json = [System.IO.File]::ReadAllText($settingsPath)
    } else {
        $json = "{`"startupConfigs`": []}"
    }

    $json = Add-ZebarStartupConfig -Json $json
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($settingsPath, $json, $utf8)
    Write-Information "Workspace bar installed."
}

function Stop-ZebarBar {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess("zebar", "Stop")) {
        return
    }

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    Get-Process -Name "zebar" | Stop-Process -Force
    $ErrorActionPreference = $previousErrorAction
}

function Start-ZebarBar {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $executable = Get-ZebarExecutable
    if (-not $executable) {
        Write-Information "Zebar is not installed yet, so the workspace bar was not started."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($executable, "Start")) {
        return
    }

    Stop-ZebarBar
    Start-Process -FilePath $executable
    Write-Information "Workspace bar started."
}

function Set-GlazeWm {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess("GlazeWM", "Install the i3 layout")) {
        return
    }

    Install-GlazeWmConfig
    Install-ZebarWorkspaceBar
    $executable = Get-GlazeWmExecutable
    if (-not $executable) {
        Write-Information "GlazeWM is not installed yet, so it was not started."
        return
    }

    Enable-GlazeWmStartup -Executable $executable
    if (Test-GlazeWmRunning) {
        Invoke-GlazeWmReload
        Start-ZebarBar
        return
    }

    Stop-ZebarBar
    Start-GlazeWmProcess -Executable $executable
}

if (Test-SelectedTask "GlazeWM") {
    Set-GlazeWm
}

if (Test-SelectedTask "LongPaths") {
    Enable-LongPath
}
if (Test-SelectedTask "Git") {
    Set-GitIdentity
}
if (Test-SelectedTask "InputLeap") {
    Set-InputLeapLayout
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
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/terminal-settings.json" -OutFile $templatePath -UseBasicParsing
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
