function Get-NodeVersionManagerHomePath {
    return @(
        $env:NVM_HOME
        [Environment]::GetEnvironmentVariable("NVM_HOME", "User")
        [Environment]::GetEnvironmentVariable("NVM_HOME", "Machine")
        (Join-Path $env:LOCALAPPDATA "nvm")
    )
}

function Get-NodeVersionManagerPath {
    foreach ($nvmHome in (Get-NodeVersionManagerHomePath | Where-Object { $_ } | Select-Object -Unique)) {
        $nvmPath = Join-Path $nvmHome "nvm.exe"
        if (Test-Path -LiteralPath $nvmPath) {
            return $nvmPath
        }
    }

    $command = Get-Command nvm.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $command = Get-Command nvm -ErrorAction SilentlyContinue
    if ($command) {
        if ($command.CommandType -eq "Function" -or $command.CommandType -eq "Alias") {
            return "nvm"
        }
        return $command.Source
    }

    return $null
}

function Invoke-NodeVersionManager {
    param(
        [Parameter(Mandatory)]
        [string]$Executable,
        [Parameter(Mandatory)]
        [string[]]$Argument
    )

    if ($Executable -eq "nvm") {
        & nvm @Argument
    } else {
        Push-Location (Split-Path -Path $Executable -Parent)
        try {
            & $Executable @Argument
        } finally {
            Pop-Location
        }
    }

    if ($LASTEXITCODE -ne 0) {
        throw "nvm $($Argument -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Set-NodeVersion {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $nodeVersion = "16.16.0"
    $nvmPackageId = "CoreyButler.NVMforWindows"

    if (-not $PSCmdlet.ShouldProcess("Node.js $nodeVersion via nvm-windows")) {
        return
    }

    $nvmPath = Get-NodeVersionManagerPath
    if (-not $nvmPath) {
        Install-RequestedPackage -Id $nvmPackageId -Option @{}
        $nvmPath = Get-NodeVersionManagerPath
    }
    if (-not $nvmPath) {
        throw "nvm-windows was installed, but nvm.exe could not be found in NVM_HOME, the default LocalAppData install directory, or PATH."
    }

    Write-Information "Installing and selecting Node.js $nodeVersion with nvm-windows."
    Invoke-NodeVersionManager -Executable $nvmPath -Argument @("install", $nodeVersion)
    Invoke-NodeVersionManager -Executable $nvmPath -Argument @("use", $nodeVersion)
}
