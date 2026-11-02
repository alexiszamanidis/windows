BeforeAll {
    $scriptPaths = @(
        (Resolve-Path ./install.ps1).Path
    ) + @(Get-ChildItem ./tasks/*.ps1 | ForEach-Object { $_.FullName })

    # Calls between these functions stay in this scope. Replacing Function:script: from a test
    # does not change that lookup, so each function checks this table before running its body.
    $script:TestFunctionOverride = @{}
    $guard = 'if ($script:TestFunctionOverride -and $script:TestFunctionOverride.ContainsKey(''{0}'')) {{ return & $script:TestFunctionOverride[''{0}''] @PSBoundParameters }}'

    foreach ($scriptPath in $scriptPaths) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if ($parseErrors.Count -gt 0) {
            throw "$scriptPath contains PowerShell syntax errors. Tokens: $($tokens.Count)."
        }

        $functions = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true)
        foreach ($function in $functions) {
            $definition = $function.Extent.Text
            $injection = $guard -f $function.Name
            if ($function.Body.ParamBlock) {
                $insertAt = $function.Body.ParamBlock.Extent.EndOffset - $function.Extent.StartOffset
            } else {
                $insertAt = ($function.Body.Extent.StartOffset - $function.Extent.StartOffset) + 1
            }

            . ([scriptblock]::Create($definition.Insert($insertAt, "`n$injection`n")))
        }
    }

    $script:installerRoot = (Resolve-Path .).Path
    $script:repoRawBase = "https://raw.githubusercontent.com/alexiszamanidis/windows"
    $script:repoRef = "HEAD"
    $script:wingetUpdateNotApplicable = -1978335189
    $script:wingetInstallCancelled = -1978334964

    function global:winget {
        throw "The unit tests called winget $($args -join ' ')."
    }

    function Add-TestFunction {
        param(
            [Parameter(Mandatory)]
            [string]$Name,
            [Parameter(Mandatory)]
            [scriptblock]$Body
        )

        if (-not (Get-Command -Name $Name -CommandType Function -ErrorAction SilentlyContinue)) {
            throw "Add-TestFunction cannot override '$Name' because that function is not loaded."
        }

        $script:TestFunctionOverride[$Name] = $Body
    }
}

Describe "Repository bootstrap" {
    It "downloads repository files from the default branch" {
        $paths = @((Resolve-Path ./install.ps1).Path) + @(Get-ChildItem ./tasks/*.ps1 | ForEach-Object { $_.FullName })
        $text = (Get-Content -Path $paths -Raw) -join "`n"
        $text | Should -Not -Match "alexiszamanidis/windows/master/"
        $text | Should -Match '\$repoRef = "HEAD"'
        $text | Should -Match "config/packages\.txt"
        $text | Should -Match "config/packages\.psd1"
        $text | Should -Match "config/node\.psd1"
        $text | Should -Match "config/git\.psd1"
        $text | Should -Match "config/wsl\.psd1"
        $text | Should -Match "config/glazewm\.yaml"
        $text | Should -Match "config/zebar/zpack\.json"
    }
}

Describe "Installer configuration" {
    BeforeAll {
        $script:nodeConfig = Import-PowerShellDataFile ./config/node.psd1
        $script:gitConfig = Import-PowerShellDataFile ./config/git.psd1
        $script:wslConfig = Import-PowerShellDataFile ./config/wsl.psd1
        $script:packageOptions = Import-PowerShellDataFile ./config/packages.psd1
        $script:packageIds = Get-InstallerPackageId -Path (Join-Path $script:installerRoot "config\packages.txt")
    }

    It "resolves repository config files from the checkout" {
        Get-InstallerConfigPath -RelativePath "config/node.psd1" | Should -Be (Join-Path $script:installerRoot "config\node.psd1")
    }

    It "stores the Node.js version and nvm package in one file" {
        $script:nodeConfig.Version | Should -Match '^\d+\.\d+\.\d+$'
        $script:nodeConfig.PackageId | Should -Match '^\S+$'
        $script:packageIds | Should -Not -Contain ([string]$script:nodeConfig.PackageId)
    }

    It "stores the Git identity in one file" {
        foreach ($name in @("user.name", "user.email", "pull.rebase", "init.defaultBranch", "fetch.prune", "credential.helper")) {
            $script:gitConfig[$name] | Should -Not -BeNullOrEmpty
        }
    }

    It "stores the WSL distro in one file" {
        $script:wslConfig.Distribution | Should -Match '^\S+$'
    }

    It "keeps package options on packages the installer installs" {
        $allowed = @("Source", "Silent", "Custom", "Processes", "Service", "RetryOnCancel")
        foreach ($id in $script:packageOptions.Keys) {
            $script:packageIds | Should -Contain $id
            foreach ($key in @($script:packageOptions[$id].Keys)) {
                $allowed | Should -Contain $key
            }
        }
    }
}

Describe "Dark mode" {
    BeforeEach {
        $script:TestFunctionOverride.Clear()
    }

    It "sets Windows and app theme values to dark" {
        $script:themeBroadcasts = 0
        Add-TestFunction Invoke-ThemeBroadcast { $script:themeBroadcasts++ }

        Set-DarkMode

        $personalize = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        $personalize.AppsUseLightTheme | Should -Be 0
        $personalize.SystemUsesLightTheme | Should -Be 0
        $script:themeBroadcasts | Should -Be 1
    }
}

Describe "Wallpaper" {
    BeforeEach {
        $script:TestFunctionOverride.Clear()
        $script:monitorCount = 1
        $script:wallpaperChanges = @()
        Add-TestFunction Get-DesktopMonitorCount { return $script:monitorCount }
        Add-TestFunction Invoke-WallpaperChange {
            param(
                [string]$Path
            )
            $script:wallpaperChanges += $Path
        }
    }

    It "fills one monitor" {
        $script:monitorCount = 1
        Set-DesktopWallpaper
        $desktop = Get-ItemProperty "HKCU:\Control Panel\Desktop"
        "$($desktop.WallpaperStyle)" | Should -Be "10"
        "$($desktop.TileWallpaper)" | Should -Be "0"
        $script:wallpaperChanges.Count | Should -Be 1
    }

    It "spans two monitors" {
        $script:monitorCount = 2
        Set-DesktopWallpaper
        $desktop = Get-ItemProperty "HKCU:\Control Panel\Desktop"
        "$($desktop.WallpaperStyle)" | Should -Be "22"
        "$($desktop.TileWallpaper)" | Should -Be "0"
        $script:wallpaperChanges.Count | Should -Be 1
    }
}

Describe "WinGet packages" {
    BeforeAll {
        $script:packageOptions = Import-PowerShellDataFile ./config/packages.psd1
    }

    BeforeEach {
        $script:TestFunctionOverride.Clear()
        $script:wingetCalls = [System.Collections.Generic.List[string]]::new()
        $script:wingetResults = [System.Collections.Generic.Queue[int]]::new()
        Add-TestFunction Invoke-WinGet {
            param(
                [string[]]$Argument
            )
            $script:wingetCalls.Add(($Argument -join " "))
            return $script:wingetResults.Dequeue()
        }
    }

    It "installs a package from the source named in packages.psd1" {
        $packageId = @($script:packageOptions.Keys | Where-Object { $script:packageOptions[$_].Source }) | Select-Object -First 1
        $packageId | Should -Not -BeNullOrEmpty
        $option = $script:packageOptions[$packageId]
        $script:wingetResults.Enqueue(0)
        Install-WinGetPackage -Id $packageId -Option $option
        $script:wingetCalls.Count | Should -Be 1
        $script:wingetCalls[0] | Should -Match "--source $([regex]::Escape([string]$option.Source))"
        $script:wingetCalls[0] | Should -Match "--id $([regex]::Escape([string]$packageId)) --exact"
    }

    It "retries a package once when its manifest requests another attempt" {
        $packageId = @($script:packageOptions.Keys | Where-Object { $script:packageOptions[$_].RetryOnCancel }) | Select-Object -First 1
        $packageId | Should -Not -BeNullOrEmpty
        $option = $script:packageOptions[$packageId]
        $script:wingetResults.Enqueue($script:wingetInstallCancelled)
        $script:wingetResults.Enqueue(0)
        Install-RequestedPackage -Id $packageId -Option $option
        $script:wingetCalls.Count | Should -Be 2
        if ($option.Silent) {
            $script:wingetCalls[0] | Should -Match "--silent"
        }
        if ($option.Custom) {
            $script:wingetCalls[0] | Should -Match "--custom $([regex]::Escape([string]$option.Custom))"
        }
        $script:wingetCalls[1] | Should -Match "--id $([regex]::Escape([string]$packageId)) --exact"
    }

    It "does not retry a cancelled install without RetryOnCancel" {
        $script:wingetResults.Enqueue($script:wingetInstallCancelled)
        { Install-RequestedPackage -Id "Git.Git" -Option @{} } | Should -Throw "WinGet failed to install Git.Git*"
        $script:wingetCalls.Count | Should -Be 1
    }
}

Describe "Node.js" {
    BeforeAll {
        $script:nodeConfig = Import-PowerShellDataFile ./config/node.psd1
    }

    BeforeEach {
        $script:TestFunctionOverride.Clear()
        $script:nvmCalls = @()
        $script:nvmExecutables = @()
        Add-TestFunction Get-NodeVersionManagerPath { return "test-nvm" }
        Add-TestFunction Invoke-NodeVersionManager {
            param(
                [string]$Executable,
                [string[]]$Argument
            )
            $script:nvmCalls += ,($Argument -join " ")
            $script:nvmExecutables += $Executable
        }
    }

    It "checks nvm-windows' default LocalAppData install directory" {
        $previousLocalAppData = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = $TestDrive
            Get-NodeVersionManagerHomePath | Should -Contain (Join-Path $TestDrive "nvm")
        } finally {
            $env:LOCALAPPDATA = $previousLocalAppData
        }
    }

    It "installs and selects the configured Node.js version" {
        Set-NodeVersion

        $script:nvmCalls | Should -HaveCount 2
        $script:nvmExecutables | Should -Be @("test-nvm", "test-nvm")
        $script:nvmCalls[0] | Should -Be "install $($script:nodeConfig.Version)"
        $script:nvmCalls[1] | Should -Be "use $($script:nodeConfig.Version)"
    }

    It "installs nvm-windows when it is not available" {
        $script:nvmLookupCount = 0
        $script:installedNvmPackage = $null
        $script:installedNvmPackageOption = $null
        Add-TestFunction Get-NodeVersionManagerPath {
            $script:nvmLookupCount++
            if ($script:nvmLookupCount -eq 1) {
                return $null
            }
            return "test-nvm"
        }
        Add-TestFunction Install-RequestedPackage {
            param(
                [string]$Id,
                [hashtable]$Option
            )
            $script:installedNvmPackage = $Id
            $script:installedNvmPackageOption = $Option
        }

        Set-NodeVersion

        $script:installedNvmPackage | Should -Be ([string]$script:nodeConfig.PackageId)
        $script:installedNvmPackageOption | Should -BeOfType [hashtable]
        $script:nvmCalls | Should -HaveCount 2
    }

    It "reports when nvm cannot be found after installation" {
        Add-TestFunction Get-NodeVersionManagerPath { return $null }
        Add-TestFunction Install-RequestedPackage { }

        { Set-NodeVersion } | Should -Throw "*nvm.exe could not be found*"
    }
}

Describe "Flow Launcher hotkey" {
    BeforeEach {
        $script:TestFunctionOverride.Clear()
    }

    It "parses the Win+P capture script" {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path ./config/flow-launcher-hotkey.ps1),
            [ref]$tokens,
            [ref]$parseErrors
        )
        $parseErrors.Count | Should -Be 0
        $capture = Get-Content ./config/flow-launcher-hotkey.ps1 -Raw
        $capture | Should -Match "SearchWindows"
        $capture | Should -Match "QueryTextBox"
        $capture | Should -Not -Match "Thread\.Sleep\(400\)"
    }

    It "adds Win+P without dropping other disabled shortcuts" {
        $path = "HKCU:\Software\WindowsSetupTest\Advanced"
        if (Test-Path -LiteralPath "HKCU:\Software\WindowsSetupTest") {
            Remove-Item -LiteralPath "HKCU:\Software\WindowsSetupTest" -Recurse -Force
        }
        New-Item -Path $path -Force | Out-Null
        New-ItemProperty -LiteralPath $path -Name "DisabledHotkeys" -PropertyType String -Value "Ep" | Out-Null

        Disable-WindowsProjectHotkey -Path $path

        Get-ItemPropertyValue -LiteralPath $path -Name "DisabledHotkeys" | Should -Be "EpP"
    }

    It "keeps an existing Win+P disable entry" {
        $path = "HKCU:\Software\WindowsSetupTest\Advanced"
        if (Test-Path -LiteralPath "HKCU:\Software\WindowsSetupTest") {
            Remove-Item -LiteralPath "HKCU:\Software\WindowsSetupTest" -Recurse -Force
        }
        New-Item -Path $path -Force | Out-Null
        New-ItemProperty -LiteralPath $path -Name "DisabledHotkeys" -PropertyType String -Value "P" | Out-Null

        Disable-WindowsProjectHotkey -Path $path

        Get-ItemPropertyValue -LiteralPath $path -Name "DisabledHotkeys" | Should -Be "P"
    }

    It "sets the Flow Launcher hotkey and keeps the other settings" {
        $directory = Join-Path $TestDrive "flow"
        New-Item -ItemType Directory -Path $directory | Out-Null
        $settingsPath = Join-Path $directory "Settings.json"
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($settingsPath, '{"Hotkey": "Alt \u002B Space", "Theme": "Dark"}', $utf8)
        Add-TestFunction Get-FlowLauncherSettingsPath { return $settingsPath }

        Set-FlowLauncherSetting

        $json = [System.IO.File]::ReadAllText($settingsPath)
        $json | Should -Match '"Hotkey": "Win \+ P"'
        $json | Should -Match '"Theme": "Dark"'
        $json | Should -Match '"StartFlowLauncherOnSystemStartup": true'
        $json | Should -Match '"Hotkey": "Win \+ Shift \+ P"'
        $json | Should -Match '"ActionKeyword": "w "'
        $json | Should -Not -Match "Alt"
    }

    It "adds the open-window hotkey beside an existing custom hotkey" {
        $directory = Join-Path $TestDrive "flow-custom"
        New-Item -ItemType Directory -Path $directory | Out-Null
        $settingsPath = Join-Path $directory "Settings.json"
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $existing = '{"Hotkey": "Alt + Space", "CustomPluginHotkeys": [{"Hotkey": "Ctrl + Alt + K", "ActionKeyword": "kill "}]}'
        [System.IO.File]::WriteAllText($settingsPath, $existing, $utf8)
        Add-TestFunction Get-FlowLauncherSettingsPath { return $settingsPath }

        Set-FlowLauncherSetting
        Set-FlowLauncherSetting

        $json = [System.IO.File]::ReadAllText($settingsPath)
        $json | Should -Match '"Hotkey": "Win \+ P"'
        $json | Should -Match '"Hotkey": "Ctrl \+ Alt \+ K"'
        $json | Should -Match '"Hotkey": "Win \+ Shift \+ P"'
        ([regex]::Matches($json, "Win \+ Shift \+ P")).Count | Should -Be 1
    }

    It "keeps a Window Walker keyword of w" {
        $directory = Join-Path $TestDrive "walker"
        New-Item -ItemType Directory -Path $directory | Out-Null
        $manifest = Join-Path $directory "plugin.json"
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($manifest, '{"ActionKeywords": [ "*" ]}', $utf8)

        Set-FlowLauncherWindowWalkerKeyword -ManifestPath $manifest

        [System.IO.File]::ReadAllText($manifest) | Should -Be '{"ActionKeywords": ["w"]}'
    }

    It "includes cloaked windows from other workspaces" {
        $directory = Join-Path $TestDrive "walker-settings"
        New-Item -ItemType Directory -Path $directory | Out-Null
        $settingsPath = Join-Path $directory "Settings.json"
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($settingsPath, '{"SearchCloakedWindows": false, "EnableQuickAccessHotKey": true}', $utf8)
        Add-TestFunction Get-FlowLauncherWindowWalkerSettingsPath { return $settingsPath }

        Set-FlowLauncherWindowWalkerSearch

        $json = [System.IO.File]::ReadAllText($settingsPath)
        $json | Should -Match '"SearchCloakedWindows": true'
        $json | Should -Match '"SearchWindowsAcrossAllVDesktop": true'
        $json | Should -Match '"EnableQuickAccessHotKey": true'
    }

    It "removes the open-window hotkey after Flow rewrites the plus sign" {
        $saved = @"
{
  "CustomPluginHotkeys": [
    {
      "Hotkey": "Win \u002B Shift \u002B P",
      "ActionKeyword": "w "
    }
  ]
}
"@
        $json = Remove-FlowLauncherWindowHotkey -Json $saved
        $json | Should -Match '"CustomPluginHotkeys": \[\]'
        $json | Should -Not -Match "Shift"
    }

    It "starts Flow Launcher when Windows releases Win+P" {
        $directory = Join-Path $TestDrive "flow-free"
        New-Item -ItemType Directory -Path $directory | Out-Null
        $settingsPath = Join-Path $directory "Settings.json"
        $script:flowStarts = 0
        $script:captures = 0
        $script:captureRemovals = 0
        Add-TestFunction Get-FlowLauncherSettingsPath { return $settingsPath }
        Add-TestFunction Stop-FlowLauncher { }
        Add-TestFunction Restart-ExplorerShell { }
        Add-TestFunction Disable-WindowsProjectHotkey { }
        Add-TestFunction Test-FlowLauncherHotkeyAvailable { return $true }
        Add-TestFunction Install-FlowLauncherWindowWalker { }
        Add-TestFunction Install-FlowLauncherHotkeyCapture { $script:captures++ }
        Add-TestFunction Remove-FlowLauncherHotkeyCapture { $script:captureRemovals++ }
        Add-TestFunction Start-FlowLauncher { $script:flowStarts++ }

        Set-FlowLauncherHotkey

        $script:flowStarts | Should -Be 1
        $script:captures | Should -Be 0
        $script:captureRemovals | Should -Be 1
        [System.IO.File]::ReadAllText($settingsPath) | Should -Match '"Hotkey": "Win \+ P"'
    }

    It "captures Win+P when Windows still owns the project shortcut" {
        $directory = Join-Path $TestDrive "flow-owned"
        New-Item -ItemType Directory -Path $directory | Out-Null
        $settingsPath = Join-Path $directory "Settings.json"
        $script:flowStarts = 0
        $script:captures = 0
        $script:captureRemovals = 0
        Add-TestFunction Get-FlowLauncherSettingsPath { return $settingsPath }
        Add-TestFunction Stop-FlowLauncher { }
        Add-TestFunction Restart-ExplorerShell { }
        Add-TestFunction Disable-WindowsProjectHotkey { }
        Add-TestFunction Test-FlowLauncherHotkeyAvailable { return $false }
        Add-TestFunction Install-FlowLauncherWindowWalker { }
        Add-TestFunction Install-FlowLauncherHotkeyCapture { $script:captures++ }
        Add-TestFunction Remove-FlowLauncherHotkeyCapture { $script:captureRemovals++ }
        Add-TestFunction Start-FlowLauncher { $script:flowStarts++ }

        Set-FlowLauncherHotkey

        $script:flowStarts | Should -Be 1
        $script:captures | Should -Be 1
        $script:captureRemovals | Should -Be 0
        [System.IO.File]::ReadAllText($settingsPath) | Should -Match '"Hotkey": "Win \+ P"'
    }
}

Describe "GlazeWM" {
    BeforeEach {
        $script:TestFunctionOverride.Clear()
    }

    It "keeps the i3 workspaces and leaves Win+P to Flow Launcher" {
        $config = Get-Content ./config/glazewm.yaml -Raw
        $config | Should -Match "display_name: '1: chrome'"
        $config | Should -Match "display_name: '2: editor'"
        $config | Should -Match "display_name: '3: terminal'"
        $config | Should -Match "display_name: '5: chat'"
        $config | Should -Match "display_name: '6: paint'"
        $config | Should -Match "display_name: '7: vpn'"
        $config | Should -Match "display_name: '9: spotify'"
        $config | Should -Match "display_name: '10: brave'"
        $config | Should -Match "show_all_in_taskbar: true"
        $config | Should -Not -Match "keep_alive:\s*true"
        $config | Should -Match "focus --workspace 10"
        $config | Should -Match "shell-exec zebar"
        $startup = if ($config -match '(?s)startup_commands:(.*?)shutdown_commands:') {
            $Matches[1]
        } else {
            ""
        }
        $startup | Should -Match "'shell-exec wt'"
        $startup | Should -Match "'shell-exec chrome'"
        $startup | Should -Not -Match "(?m)^\s*-\s*'shell-exec (?:slack|brave)(?:\s|')"
        $config | Should -Match "shell-exec wt"
        $config | Should -Match "top: '40px'"
        $config | Should -Match "equals: 'zebar'"
        $config | Should -Match "\['lwin\+enter'\]"
        $config | Should -Not -Match "'lwin\+p'"
        $config | Should -Not -Match "'lwin\+l'"
        Test-Path -LiteralPath ./config/chrome-startup.ps1 | Should -BeTrue
    }

    It "writes the config and the login entry" {
        $directory = Join-Path $TestDrive "glazewm"
        $configPath = Join-Path $directory "config.yaml"
        $runPath = "HKCU:\Software\WindowsSetupTest\Run"
        if (Test-Path -LiteralPath "HKCU:\Software\WindowsSetupTest") {
            Remove-Item -LiteralPath "HKCU:\Software\WindowsSetupTest" -Recurse -Force
        }
        Add-TestFunction Get-GlazeWmConfigPath { return $configPath }

        Install-GlazeWmConfig
        Enable-GlazeWmStartup -RunPath $runPath -Executable "C:\Program Files\glzr.io\GlazeWM\glazewm.exe"

        $config = [System.IO.File]::ReadAllText($configPath)
        $config | Should -Match "display_name: '1: chrome'"
        $config | Should -Match "move --workspace 2"
        $linkedConfig = Get-Item -LiteralPath $configPath
        $linkedConfig.LinkType | Should -Be "SymbolicLink"
        @($linkedConfig.Target)[0] | Should -Be (Resolve-Path ./config/glazewm.yaml).Path
        $startupPath = Join-Path $directory "chrome-startup.ps1"
        $linkedStartup = Get-Item -LiteralPath $startupPath
        $linkedStartup.LinkType | Should -Be "SymbolicLink"
        @($linkedStartup.Target)[0] | Should -Be (Resolve-Path ./config/chrome-startup.ps1).Path
        Get-ItemPropertyValue -LiteralPath $runPath -Name "GlazeWM" | Should -Be '"C:\Program Files\glzr.io\GlazeWM\glazewm.exe"'
    }

    It "reloads a running GlazeWM instead of starting another one" {
        $directory = Join-Path $TestDrive "glazewm-running"
        $configPath = Join-Path $directory "config.yaml"
        $script:reloads = 0
        $script:starts = 0
        Add-TestFunction Get-GlazeWmConfigPath { return $configPath }
        Add-TestFunction Get-GlazeWmExecutable { return "C:\Program Files\glzr.io\GlazeWM\glazewm.exe" }
        Add-TestFunction Install-ZebarWorkspaceBar { }
        Add-TestFunction Enable-GlazeWmStartup { }
        Add-TestFunction Test-GlazeWmRunning { return $true }
        Add-TestFunction Start-ZebarBar { }
        Add-TestFunction Invoke-GlazeWmReload { $script:reloads++ }
        Add-TestFunction Start-GlazeWmProcess { $script:starts++ }

        Set-GlazeWm

        $script:reloads | Should -Be 1
        $script:starts | Should -Be 0
        [System.IO.File]::ReadAllText($configPath) | Should -Match "display_name: '10: brave'"
        Test-Path -LiteralPath (Join-Path $directory "chrome-startup.ps1") | Should -BeTrue
    }

    It "starts GlazeWM when it is installed and not running" {
        $directory = Join-Path $TestDrive "glazewm-stopped"
        $configPath = Join-Path $directory "config.yaml"
        $script:reloads = 0
        $script:starts = 0
        Add-TestFunction Get-GlazeWmConfigPath { return $configPath }
        Add-TestFunction Get-GlazeWmExecutable { return "C:\Program Files\glzr.io\GlazeWM\glazewm.exe" }
        Add-TestFunction Install-ZebarWorkspaceBar { }
        Add-TestFunction Stop-ZebarBar { }
        Add-TestFunction Enable-GlazeWmStartup { }
        Add-TestFunction Test-GlazeWmRunning { return $false }
        Add-TestFunction Invoke-GlazeWmReload { $script:reloads++ }
        Add-TestFunction Start-GlazeWmProcess { $script:starts++ }

        Set-GlazeWm

        $script:reloads | Should -Be 0
        $script:starts | Should -Be 1
    }

    It "writes the config when GlazeWM is not installed yet" {
        $directory = Join-Path $TestDrive "glazewm-missing"
        $configPath = Join-Path $directory "config.yaml"
        $script:starts = 0
        Add-TestFunction Get-GlazeWmConfigPath { return $configPath }
        Add-TestFunction Get-GlazeWmExecutable { return $null }
        Add-TestFunction Install-ZebarWorkspaceBar { }
        Add-TestFunction Start-GlazeWmProcess { $script:starts++ }

        Set-GlazeWm

        $script:starts | Should -Be 0
        [System.IO.File]::ReadAllText($configPath) | Should -Match "lwin\+1"
    }

    It "installs the workspace bar and keeps other Zebar widgets" {
        $directory = Join-Path $TestDrive "zebar"
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        New-Item -ItemType Directory -Path $directory | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $directory "settings.json"),
            '{"startupConfigs": [{"pack": "starter", "widget": "vanilla", "preset": "default"}]}',
            $utf8
        )
        Add-TestFunction Get-ZebarConfigDirectory { return $directory }

        Install-ZebarWorkspaceBar

        $pack = Join-Path $directory "workspaces\zpack.json"
        Test-Path -LiteralPath $pack | Should -BeTrue
        [System.IO.File]::ReadAllText($pack) | Should -Match '"includeFiles": \["\*\.html"\]'
        $bar = [System.IO.File]::ReadAllText((Join-Path $directory "workspaces\index.html"))
        $bar | Should -Match "currentWorkspaces"
        $bar | Should -Match "unread"
        $bar | Should -Match "workspaceLayoutKey"
        $bar | Should -Match 'type: "systray"'
        $bar | Should -Not -Match 'type: "audio"'
        $bar | Should -Match "volume\.ps1"
        Test-Path -LiteralPath (Join-Path $directory "workspaces\volume.ps1") | Should -BeTrue
        $settings = [System.IO.File]::ReadAllText((Join-Path $directory "settings.json"))
        $settings | Should -Match '"pack": "workspaces"'
        $settings | Should -Match '"widget": "vanilla"'
    }

    It "leaves an existing workspace bar entry in place" {
        $json = '{"startupConfigs": [{"pack": "workspaces", "widget": "bar", "preset": "default"}]}'
        Add-ZebarStartupConfig -Json $json | Should -Be $json
    }
}

Describe "WSL" {
    BeforeAll {
        $script:wslDistribution = [string](Import-PowerShellDataFile ./config/wsl.psd1).Distribution
    }

    BeforeEach {
        $script:TestFunctionOverride.Clear()
        $script:wslCalls = [System.Collections.Generic.List[string]]::new()
        $script:wslList = [string[]]@("  NAME      STATE           VERSION")
        Add-TestFunction Get-WslOutput {
            param([string[]]$Arguments)
            $script:wslCalls.Add(($Arguments -join " "))
            $lines = if ($Arguments -contains "--list") { $script:wslList } else { [string[]]@() }
            return [pscustomobject]@{
                ExitCode = 0
                Output   = ($lines -join "`n")
                Lines    = $lines
            }
        }
    }

    It "installs the configured distro when WSL has none" {
        Install-WslUbuntu

        $script:wslCalls | Should -Contain "--set-default-version 2"
        $script:wslCalls | Should -Contain "--install --distribution $($script:wslDistribution) --no-launch --web-download"
        $script:wslCalls | Should -Contain "--set-default $($script:wslDistribution)"
    }

    It "keeps an installed distro with the configured name" {
        $script:wslList = [string[]]@(
            "  NAME      STATE           VERSION"
            "* $($script:wslDistribution)    Stopped         2"
        )

        Install-WslUbuntu

        @($script:wslCalls | Where-Object { $_ -match "--distribution " }) | Should -BeNullOrEmpty
        $script:wslCalls | Should -Contain "--set-default $($script:wslDistribution)"
    }

    It "converts a versioned distro name to WSL2" {
        $versioned = "$($script:wslDistribution)-24.04"
        $script:wslList = [string[]]@(
            "  NAME      STATE           VERSION"
            "  $versioned    Stopped         1"
        )

        Install-WslUbuntu

        @($script:wslCalls | Where-Object { $_ -match "--distribution " }) | Should -BeNullOrEmpty
        $script:wslCalls | Should -Contain "--set-version $versioned 2"
        $script:wslCalls | Should -Contain "--set-default $versioned"
        Get-PreferredWslDistroName | Should -Be $versioned
    }

    It "stops when WSL asks for a restart" {
        Add-TestFunction Get-WslOutput {
            param([string[]]$Arguments)
            $script:wslCalls.Add(($Arguments -join " "))
            return [pscustomobject]@{
                ExitCode = 1
                Output   = "Changes will not be effective until the system is rebooted."
                Lines    = [string[]]@("Changes will not be effective until the system is rebooted.")
            }
        }

        Install-WslUbuntu

        @($script:wslCalls | Where-Object { $_ -match "--distribution " }) | Should -BeNullOrEmpty
    }
}

Describe "Windows Terminal profiles" {
    It "uses Windows Terminal's profile id for a distro name" {
        (Get-WslTerminalProfileGuid -DistroName "Ubuntu").Trim("{}") | Should -Be "2c4de342-38b7-51cf-b940-2309a097f518"
        (Get-WslTerminalProfileGuid -DistroName "Ubuntu-24.04").Trim("{}") | Should -Be "963ff2f7-6aed-5ce3-9d91-90d99571f53a"
    }
}
