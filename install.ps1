$ErrorActionPreference = "Stop"
$InformationPreference = "Continue"

$repoRawBase = "https://raw.githubusercontent.com/alexiszamanidis/windows"
$repoRef = "HEAD"
$installerRoot = $PSScriptRoot
$packagesFile = if ($installerRoot) {
    Join-Path $installerRoot "config\packages.txt"
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

# The one-liner has no checkout. Read each task script from GitHub and run the text in this scope.
# Running the text keeps the one-liner working when Windows blocks unsigned script files.
$installerTasks = @(
    "tasks/Appearance.ps1"
    "tasks/Git.ps1"
    "tasks/Packages.ps1"
    "tasks/FlowLauncher.ps1"
    "tasks/GlazeWm.ps1"
    "tasks/InputLeap.ps1"
    "tasks/Wsl.ps1"
    "tasks/Terminal.ps1"
)
foreach ($relativePath in $installerTasks) {
    if ($installerRoot) {
        . (Join-Path $installerRoot ($relativePath -replace "/", "\"))
    } else {
        $taskUri = "$repoRawBase/$repoRef/$relativePath"
        try {
            $taskScript = (Invoke-WebRequest -Uri $taskUri -UseBasicParsing).Content
        } catch {
            throw "Could not download $relativePath from GitHub."
        }
        . ([scriptblock]::Create($taskScript))
    }
}

if (-not (Test-Path $packagesFile)) {
    Write-Information "packages.txt not found locally. Downloading from GitHub..."
    try {
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/config/packages.txt" -OutFile $packagesFile -UseBasicParsing
    } catch {
        throw "packages.txt not found at $packagesFile and download from GitHub failed."
    }
}

$packages = Get-Content $packagesFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") }

$packageOptionsFile = if ($installerRoot) {
    Join-Path $installerRoot "config\packages.psd1"
} else {
    Join-Path $env:TEMP "windows-packages.psd1"
}

if (-not (Test-Path $packageOptionsFile)) {
    Write-Information "packages.psd1 not found locally. Downloading from GitHub..."
    try {
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/config/packages.psd1" -OutFile $packageOptionsFile -UseBasicParsing
    } catch {
        throw "packages.psd1 not found at $packageOptionsFile and download from GitHub failed."
    }
}

$packageOptions = Import-PowerShellDataFile $packageOptionsFile

if (Test-SelectedTask "DarkMode") {
    Set-DarkMode
}
if (Test-SelectedTask "Wallpaper") {
    Set-DesktopWallpaper
}
if (Test-SelectedTask "Explorer") {
    Set-ExplorerPreference
}

if (Test-SelectedTask "Packages") {
    if ($packages.Count -eq 0) {
        Write-Information "packages.txt has no package IDs yet."
    }

    foreach ($id in $packages) {
        Install-RequestedPackage -Id $id -Option $packageOptions[$id]
    }
}

if (Test-SelectedTask "FlowLauncher") {
    Set-FlowLauncherHotkey
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

if (Test-SelectedTask "Wsl") {
    Install-WslUbuntu
}
if (Test-SelectedTask "Font") {
    Install-HackNerdFont
}
if (Test-SelectedTask "Terminal") {
    Set-WindowsTerminalSetting
}
