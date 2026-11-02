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

    $settings = Import-InstallerDataFile -RelativePath "config/git.psd1"
    foreach ($name in @("user.name", "user.email", "pull.rebase", "init.defaultBranch", "fetch.prune", "credential.helper")) {
        if (-not $settings.ContainsKey($name) -or [string]::IsNullOrWhiteSpace([string]$settings[$name])) {
            throw "config/git.psd1 must set $name."
        }
    }

    foreach ($name in $settings.Keys) {
        & $gitCommand config --global $name $settings[$name]
        if ($LASTEXITCODE -ne 0) {
            throw "Could not set Git $name (exit code $LASTEXITCODE)."
        }
    }

    Write-Information "Git identity is set."
}
