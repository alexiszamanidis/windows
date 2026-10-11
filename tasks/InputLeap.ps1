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

    $sourcePath = if ($installerRoot) {
        Join-Path $installerRoot "config\input-leap.sgc"
    } else {
        $null
    }
    if (-not ($sourcePath -and (Test-Path -LiteralPath $sourcePath))) {
        $sourcePath = Join-Path $env:TEMP "windows-input-leap.sgc"
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/config/input-leap.sgc" -OutFile $sourcePath -UseBasicParsing
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
