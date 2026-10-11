function Get-WslOutput {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    # wsl.exe writes UTF-16 from Windows PowerShell and treats stderr as an error record.
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lines = @(& wsl @Arguments 2>&1 | ForEach-Object { "$_" -replace "`0", "" })
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }

    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($lines -join [Environment]::NewLine)
        Lines    = $lines
    }
}

function Test-WslRebootRequired {
    param(
        [Parameter(Mandatory)]
        $Result
    )

    return $Result.Output -match "(?i)\b(reboot|restart)"
}

function Test-WslPlatformMissing {
    param(
        [Parameter(Mandatory)]
        $Result
    )

    return $Result.Output -match "(?i)not installed|WSL_E_WSL_OPTIONAL_COMPONENT_REQUIRED|0x8007019e"
}

function Get-WslDistroFromOutput {
    param([string[]]$Lines)

    $distros = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $Lines) {
        $clean = $line.Trim()
        if ($clean -match '^\*?\s*(\S+)\s+\S+\s+(\d+)\s*$') {
            $distro = [pscustomobject]@{
                Name    = $Matches[1]
                Version = $Matches[2]
            }
            [void]$distros.Add($distro)
        }
    }
    Write-Output -InputObject $distros -NoEnumerate
}

function Get-WslDistroList {
    $listed = Get-WslOutput -Arguments @("--list", "--verbose")
    if ($listed.ExitCode -eq 0) {
        Write-Output -InputObject (Get-WslDistroFromOutput -Lines $listed.Lines) -NoEnumerate
        return
    }

    if (Test-WslRebootRequired $listed) {
        throw "WSL_REBOOT_REQUIRED"
    }

    # A fresh WSL install reports this instead of an empty table.
    if ($listed.Output -match "(?i)no installed distributions") {
        Write-Output -InputObject ([System.Collections.Generic.List[object]]::new()) -NoEnumerate
        return
    }

    if (-not (Test-WslPlatformMissing $listed)) {
        throw "Could not list WSL distros (exit code $($listed.ExitCode)). $($listed.Output)"
    }

    Write-Information "Installing the Windows Subsystem for Linux."
    $platform = Get-WslOutput -Arguments @("--install", "--no-distribution")
    if (Test-WslRebootRequired $platform) {
        throw "WSL_REBOOT_REQUIRED"
    }
    if ($platform.ExitCode -ne 0) {
        throw "WSL installation failed (exit code $($platform.ExitCode)). $($platform.Output)"
    }

    $listed = Get-WslOutput -Arguments @("--list", "--verbose")
    if ($listed.ExitCode -ne 0) {
        if (Test-WslRebootRequired $listed) {
            throw "WSL_REBOOT_REQUIRED"
        }
        if ($listed.Output -match "(?i)no installed distributions") {
            Write-Output -InputObject ([System.Collections.Generic.List[object]]::new()) -NoEnumerate
            return
        }
        throw "Could not list WSL distros (exit code $($listed.ExitCode)). $($listed.Output)"
    }

    Write-Output -InputObject (Get-WslDistroFromOutput -Lines $listed.Lines) -NoEnumerate
}

function Install-WslUbuntu {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $distroName = "Ubuntu"
    if (-not $PSCmdlet.ShouldProcess($distroName, "Install WSL2 and Ubuntu")) {
        return
    }

    try {
        $distros = Get-WslDistroList
        $defaultVersion = Get-WslOutput -Arguments @("--set-default-version", "2")
        if (Test-WslRebootRequired $defaultVersion) {
            throw "WSL_REBOOT_REQUIRED"
        }
        if ($defaultVersion.ExitCode -ne 0) {
            throw "Could not set WSL2 as the default version (exit code $($defaultVersion.ExitCode)). $($defaultVersion.Output)"
        }

        $existing = $distros | Where-Object { $_.Name -eq $distroName } | Select-Object -First 1
        if (-not $existing) {
            $existing = $distros | Where-Object { $_.Name -like "Ubuntu-*" } | Select-Object -First 1
        }

        if (-not $existing) {
            Write-Information "Installing Ubuntu for WSL."
            $installed = Get-WslOutput -Arguments @("--install", "--distribution", $distroName, "--no-launch", "--web-download")
            if (Test-WslRebootRequired $installed) {
                throw "WSL_REBOOT_REQUIRED"
            }
            if ($installed.ExitCode -ne 0) {
                throw "Ubuntu installation failed (exit code $($installed.ExitCode)). $($installed.Output)"
            }
            $existing = [pscustomobject]@{
                Name    = $distroName
                Version = "2"
            }
        } else {
            Write-Information "$($existing.Name) is already installed."
        }

        if ($existing.Version -ne "2") {
            Write-Information "Converting $($existing.Name) to WSL2."
            $converted = Get-WslOutput -Arguments @("--set-version", $existing.Name, "2")
            if (Test-WslRebootRequired $converted) {
                throw "WSL_REBOOT_REQUIRED"
            }
            if ($converted.ExitCode -ne 0) {
                throw "Could not convert $($existing.Name) to WSL2 (exit code $($converted.ExitCode)). $($converted.Output)"
            }
        }

        $defaultDistro = Get-WslOutput -Arguments @("--set-default", $existing.Name)
        if ($defaultDistro.ExitCode -ne 0) {
            throw "Could not set $($existing.Name) as the default WSL distro (exit code $($defaultDistro.ExitCode)). $($defaultDistro.Output)"
        }

        Write-Information "$($existing.Name) is ready on WSL2."
        Write-Information "Open Ubuntu and create your Linux user if this is the first launch."
        Write-Information "Then install Linux packages with the Ansible repo. This script stops before that."
        Write-Information "git clone https://github.com/alexiszamanidis/ansible.git ~/ansible && cd ~/ansible && git remote set-url origin git@github.com:alexiszamanidis/ansible.git && ./install"
    } catch {
        if ($_.Exception.Message -eq "WSL_REBOOT_REQUIRED") {
            Write-Information "Restart Windows, then run this installer again to install Ubuntu."
            return
        }
        throw
    }
}

function Get-PreferredWslDistroName {
    $listed = Get-WslOutput -Arguments @("--list", "--verbose")
    if ($listed.ExitCode -ne 0 -and $listed.Output -notmatch "(?i)no installed distributions") {
        return "Ubuntu"
    }

    $distros = @(Get-WslDistroFromOutput -Lines $listed.Lines)
    $exact = $distros | Where-Object { $_.Name -eq "Ubuntu" } | Select-Object -First 1
    if ($exact) {
        return $exact.Name
    }

    $versioned = $distros | Where-Object { $_.Name -like "Ubuntu*" } | Select-Object -First 1
    if ($versioned) {
        return $versioned.Name
    }

    return "Ubuntu"
}
