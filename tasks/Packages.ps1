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
