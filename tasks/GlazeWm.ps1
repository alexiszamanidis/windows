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
        Join-Path $installerRoot "config\glazewm.yaml"
    } else {
        $null
    }
    if (-not ($sourcePath -and (Test-Path -LiteralPath $sourcePath))) {
        $sourcePath = Join-Path $env:TEMP "windows-glazewm.yaml"
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/config/glazewm.yaml" -OutFile $sourcePath -UseBasicParsing
    }

    $chromeStartupSource = if ($installerRoot) {
        Join-Path $installerRoot "config\chrome-startup.ps1"
    } else {
        $null
    }
    if (-not ($chromeStartupSource -and (Test-Path -LiteralPath $chromeStartupSource))) {
        $chromeStartupSource = Join-Path $env:TEMP "windows-chrome-startup.ps1"
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/config/chrome-startup.ps1" -OutFile $chromeStartupSource -UseBasicParsing
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
    # Start it outside this console so closing the installer does not stop GlazeWM.
    Start-DetachedProcess -FilePath (Join-Path $env:SystemRoot "System32\cmd.exe") -ArgumentList @(
        "/c", "start", "", $Executable
    )
}

function Start-DetachedProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string[]]$ArgumentList
    )

    if (-not $PSCmdlet.ShouldProcess($FilePath, "Start detached")) {
        return
    }

    # Win32_Process.Create runs from WMI, which has no console and is outside this
    # window's process job. Zebar attaches to its parent console and exits with it.
    $command = "`"$FilePath`""
    foreach ($argument in $ArgumentList) {
        if ($argument.Length -eq 0 -or $argument -match '[\s"]') {
            $command += " `"$($argument.Replace('"', '\"'))`""
        } else {
            $command += " $argument"
        }
    }

    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $command }
    if ($result.ReturnValue -ne 0) {
        throw "Could not start $FilePath (WMI error $($result.ReturnValue))."
    }
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
        Join-Path $installerRoot "config\zebar"
    } else {
        $null
    }
    if (-not ($sourceDirectory -and (Test-Path -LiteralPath (Join-Path $sourceDirectory "zpack.json")))) {
        $sourceDirectory = Join-Path $env:TEMP "windows-zebar"
        New-Item -ItemType Directory -Path $sourceDirectory -Force | Out-Null
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/config/zebar/zpack.json" -OutFile (Join-Path $sourceDirectory "zpack.json") -UseBasicParsing
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/config/zebar/index.html" -OutFile (Join-Path $sourceDirectory "index.html") -UseBasicParsing
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/config/zebar/volume.ps1" -OutFile (Join-Path $sourceDirectory "volume.ps1") -UseBasicParsing
    }

    New-Item -ItemType Directory -Path $packDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceDirectory "zpack.json") -Destination (Join-Path $packDirectory "zpack.json") -Force
    Copy-Item -LiteralPath (Join-Path $sourceDirectory "index.html") -Destination (Join-Path $packDirectory "index.html") -Force
    Copy-Item -LiteralPath (Join-Path $sourceDirectory "volume.ps1") -Destination (Join-Path $packDirectory "volume.ps1") -Force

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

function Test-ZebarAssetPort {
    # Zebar serves widget pages from 127.0.0.1:6124. A force-kill can leave that
    # listener behind after the process is gone, so Get-NetTCPConnection is not enough.
    $lines = & netstat.exe -ano -p tcp
    foreach ($line in $lines) {
        if ($line -match "127\.0\.0\.1:6124\s+\S+\s+LISTENING") {
            return $true
        }
    }

    return $false
}

function Wait-ZebarStopped {
    param([int]$TimeoutSeconds = 8)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $running = @(Get-Process -Name "zebar" -ErrorAction SilentlyContinue)
        if ($running.Count -eq 0 -and -not (Test-ZebarAssetPort)) {
            return $true
        }

        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Wait-ZebarAssetServer {
    param([int]$TimeoutSeconds = 8)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-ZebarAssetPort) {
            return $true
        }

        if (-not (Get-Process -Name "zebar" -ErrorAction SilentlyContinue)) {
            return $false
        }

        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)

    return (Test-ZebarAssetPort)
}

function Stop-ZebarBar {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess("zebar", "Stop")) {
        return
    }

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $processes = @(Get-Process -Name "zebar")
    foreach ($process in $processes) {
        $process.CloseMainWindow() | Out-Null
    }

    if (-not (Wait-ZebarStopped -TimeoutSeconds 3)) {
        $ids = @($processes | ForEach-Object { $_.Id })
        $children = @()
        if ($ids.Count -gt 0) {
            $children = @(Get-CimInstance Win32_Process | Where-Object {
                $_.Name -eq "msedgewebview2.exe" -and ($ids -contains $_.ParentProcessId)
            })
        }

        Get-Process -Name "zebar" | Stop-Process -Force
        foreach ($child in $children) {
            Stop-Process -Id $child.ProcessId -Force
        }
    }

    $ErrorActionPreference = $previousErrorAction
    Wait-ZebarStopped -TimeoutSeconds 8 | Out-Null
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
    # startup -q keeps the provider refresh from logging into the parent console.
    # Starting again before port 6124 is released leaves the new bar unable to load.
    Start-DetachedProcess -FilePath $executable -ArgumentList @("startup", "-q")
    if (-not (Wait-ZebarAssetServer)) {
        Stop-ZebarBar
        Start-DetachedProcess -FilePath $executable -ArgumentList @("startup", "-q")
        Wait-ZebarAssetServer | Out-Null
    }

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
