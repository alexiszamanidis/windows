# 0x8A15002B: package is already installed and no newer version is available.
$wingetUpdateNotApplicable = -1978335189
# 0x8A150006: ShellExecute failed. The installer process then exits 3221225477 (0xC0000005).
$wingetShellExecFailed = -1978335226
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
    if ($ServiceName -and (Get-Command -Name Stop-Service -ErrorAction SilentlyContinue)) {
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

    if (-not $Option) {
        $Option = @{}
    }

    Write-Information "Installing $Id"
    if ($Option.RetryOnShellExec -and $Option.Processes) {
        Write-Information "Closing $Id before WinGet runs so its installer does not crash."
        Stop-PackageApplication -ProcessName $Option.Processes -ServiceName $Option.Service
    }
    $exitCode = Install-WinGetPackage -Id $Id -Option $Option
    $closeAndRetry = $false
    if ($Option.RetryOnCancel -and $exitCode -eq $wingetInstallCancelled) {
        # The silent installer exits 5 when it cannot close a program using its files.
        Write-Information "$Id installer aborted. Closing its processes and retrying."
        $closeAndRetry = $true
    }
    elseif ($Option.RetryOnShellExec -and $exitCode -eq $wingetShellExecFailed) {
        Write-Information "$Id installer crashed while the application was open. Closing its processes and retrying."
        $closeAndRetry = $true
    }
    if ($closeAndRetry) {
        Stop-PackageApplication -ProcessName $Option.Processes -ServiceName $Option.Service
        $exitCode = Install-WinGetPackage -Id $Id -Option $Option
    }
    if ($exitCode -eq $wingetUpdateNotApplicable) {
        Write-Information "$Id is already installed and up to date."
        return
    }
    if ($Option.RetryOnShellExec -and $exitCode -eq $wingetShellExecFailed) {
        Write-Information "$Id is already present. WinGet's installer crashed, so the existing install is kept."
        return
    }
    if ($exitCode -ne 0) {
        throw "WinGet failed to install $Id (exit code $exitCode)."
    }
}
