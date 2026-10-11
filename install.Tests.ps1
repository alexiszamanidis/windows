BeforeAll {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path ./install.ps1),
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        throw "install.ps1 contains PowerShell syntax errors. Tokens: $($tokens.Count)."
    }

    # Calls between these functions stay in this scope. Replacing Function:script: from a test
    # does not change that lookup, so each function checks this table before running its body.
    $script:TestFunctionOverride = @{}
    $guard = 'if ($script:TestFunctionOverride -and $script:TestFunctionOverride.ContainsKey(''{0}'')) {{ return & $script:TestFunctionOverride[''{0}''] @PSBoundParameters }}'

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
    It "downloads sibling files from the default branch" {
        $text = Get-Content ./install.ps1 -Raw
        $text | Should -Not -Match "alexiszamanidis/windows/master/"
        $text | Should -Match '\$repoRef = "HEAD"'
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

    It "installs the Store package from msstore" {
        $script:wingetResults.Enqueue(0)
        Install-WinGetPackage -Id "9NKSQGP7F2NH" -Option @{ Source = "msstore" }
        $script:wingetCalls.Count | Should -Be 1
        $script:wingetCalls[0] | Should -Match "--source msstore"
        $script:wingetCalls[0] | Should -Match "--id 9NKSQGP7F2NH --exact"
    }

    It "retries Input Leap once when the installer is cancelled" {
        $script:wingetResults.Enqueue($script:wingetInstallCancelled)
        $script:wingetResults.Enqueue(0)
        Install-RequestedPackage -Id "input-leap.input-leap" -Option @{
            Silent        = $true
            Custom        = "/FORCECLOSEAPPLICATIONS"
            RetryOnCancel = $true
        }
        $script:wingetCalls.Count | Should -Be 2
        $script:wingetCalls[0] | Should -Match "--silent"
        $script:wingetCalls[0] | Should -Match "--custom /FORCECLOSEAPPLICATIONS"
        $script:wingetCalls[1] | Should -Match "--id input-leap.input-leap --exact"
    }

    It "does not retry a cancelled install without RetryOnCancel" {
        $script:wingetResults.Enqueue($script:wingetInstallCancelled)
        { Install-RequestedPackage -Id "Git.Git" -Option @{} } | Should -Throw "WinGet failed to install Git.Git*"
        $script:wingetCalls.Count | Should -Be 1
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
            (Resolve-Path ./flow-launcher-hotkey.ps1),
            [ref]$tokens,
            [ref]$parseErrors
        )
        $parseErrors.Count | Should -Be 0
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
        $json | Should -Not -Match "Alt"
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
