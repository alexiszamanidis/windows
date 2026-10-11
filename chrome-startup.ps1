# Launch startup apps onto their workspaces.
#   Default     -> workspace 1, monitor 0 (left)
#   Outlook     -> workspace 4, monitor 0 (left)
#   Profile 3   -> workspace 8, monitor 0 (left)
#   Profile 4   -> workspace 9, monitor 1 (right)

$ErrorActionPreference = "Stop"

$chrome = Join-Path ${env:ProgramFiles} "Google\Chrome\Application\chrome.exe"
if (-not (Test-Path -LiteralPath $chrome)) {
    $chrome = Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"
}
if (-not (Test-Path -LiteralPath $chrome)) {
    Write-Error "Google Chrome was not found."
}

$outlook = @(
    (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\olk.exe")
    (Join-Path ${env:ProgramFiles} "Microsoft Office\root\Office16\OUTLOOK.EXE")
    (Join-Path ${env:ProgramFiles(x86)} "Microsoft Office\root\Office16\OUTLOOK.EXE")
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $outlook) {
    $outlookCommand = Get-Command -Name "olk", "outlook" -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($outlookCommand) {
        $outlook = $outlookCommand.Source
    }
}

$glazewmCli = @(
    (Join-Path ${env:ProgramFiles} "glzr.io\GlazeWM\cli\glazewm.exe")
    (Join-Path ${env:ProgramFiles} "glzr.io\GlazeWM\glazewm.exe")
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

function Focus-Workspace([string]$Workspace) {
    if (-not $glazewmCli) {
        return
    }
    & $glazewmCli command focus --workspace $Workspace | Out-Null
}

function Start-AppOnWorkspace {
    param(
        [Parameter(Mandatory)]
        [string]$Workspace,
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    Focus-Workspace $Workspace
    Start-Sleep -Milliseconds 500

    if ($ArgumentList.Count -gt 0) {
        Start-Process -FilePath $FilePath -ArgumentList $ArgumentList
    } else {
        Start-Process -FilePath $FilePath
    }
    Start-Sleep -Milliseconds 1500
}

function Start-ChromeOnWorkspace {
    param(
        [Parameter(Mandatory)]
        [string]$Workspace,
        [Parameter(Mandatory)]
        [string]$ProfileDirectory,
        [switch]$Incognito
    )

    $argumentList = @(
        "--profile-directory=`"$ProfileDirectory`""
        "--new-window"
    )
    if ($Incognito) {
        $argumentList += "--incognito"
    }

    Start-AppOnWorkspace -Workspace $Workspace -FilePath $chrome -ArgumentList $argumentList
}

Start-ChromeOnWorkspace -Workspace "1" -ProfileDirectory "Default"
if ($outlook) {
    Start-AppOnWorkspace -Workspace "4" -FilePath $outlook
}
Start-ChromeOnWorkspace -Workspace "8" -ProfileDirectory "Profile 3"
Start-ChromeOnWorkspace -Workspace "9" -ProfileDirectory "Profile 4"
