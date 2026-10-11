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
        Join-Path $installerRoot "config\flow-launcher-hotkey.ps1"
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    if ($source -and (Test-Path -LiteralPath $source)) {
        Copy-Item -LiteralPath $source -Destination $destination -Force
    } else {
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/config/flow-launcher-hotkey.ps1" -OutFile $destination -UseBasicParsing
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
