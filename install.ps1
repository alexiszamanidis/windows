$ErrorActionPreference = "Stop"
$InformationPreference = "Continue"

$repoRawBase = "https://raw.githubusercontent.com/alexiszamanidis/windows"
$packagesFile = if ($PSScriptRoot) {
    Join-Path $PSScriptRoot "packages.txt"
} else {
    Join-Path $env:TEMP "windows-packages.txt"
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Information "Administrator permission is required. Restarting elevated..."
    if ($PSCommandPath) {
        $argumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath)
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

if ($packages.Count -eq 0) {
    Write-Information "packages.txt has no package IDs yet."
    exit 0
}

# 0x8A15002B: package is already installed and no newer version is available.
$wingetUpdateNotApplicable = -1978335189
# 0x8A15010C: Inno Setup aborted a suppressed prompt and WinGet reports it as cancelled.
$wingetInstallCancelled = -1978334964

function Stop-InputLeapProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess("Input Leap")) {
        return
    }

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    foreach ($name in @("input-leap", "input-leapd", "input-leapc", "input-leaps")) {
        Get-Process -Name $name | Stop-Process -Force
    }
    Stop-Service -Name "InputLeap" -Force
    $ErrorActionPreference = $previousErrorAction
}

function Install-WinGetPackage {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Id)

    if (-not $PSCmdlet.ShouldProcess($Id)) {
        return 0
    }

    $arguments = @(
        "install",
        "--id", $Id,
        "--exact",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity"
    )

    if ($Id -eq "input-leap.input-leap") {
        # The silent installer exits 5 when it cannot close a program using its files.
        Stop-InputLeapProcess
        $arguments += @("--silent", "--custom", "/FORCECLOSEAPPLICATIONS")
    }

    & winget @arguments | Out-Host
    return $LASTEXITCODE
}

foreach ($id in $packages) {
    Write-Information "Installing $id"
    $exitCode = Install-WinGetPackage $id
    if ($id -eq "input-leap.input-leap" -and $exitCode -eq $wingetInstallCancelled) {
        Write-Information "Input Leap installer aborted. Closing its processes and retrying."
        $exitCode = Install-WinGetPackage $id
    }
    if ($exitCode -eq $wingetUpdateNotApplicable) {
        Write-Information "$id is already installed and up to date."
        continue
    }
    if ($exitCode -ne 0) {
        throw "WinGet failed to install $id (exit code $exitCode)."
    }
}
