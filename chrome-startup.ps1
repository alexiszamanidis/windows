# Launch each Chrome profile onto its monitor/workspace.
#   Default   -> workspace 1, monitor 0 (left)
#   Profile 4 -> workspace 9, monitor 1 (right)
#   Profile 3 -> workspace 10, monitor 1 (right)

$ErrorActionPreference = "Stop"

$chrome = Join-Path ${env:ProgramFiles} "Google\Chrome\Application\chrome.exe"
if (-not (Test-Path -LiteralPath $chrome)) {
    $chrome = Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"
}
if (-not (Test-Path -LiteralPath $chrome)) {
    Write-Error "Google Chrome was not found."
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

function Start-ChromeOnWorkspace {
    param(
        [Parameter(Mandatory)]
        [string]$Workspace,
        [Parameter(Mandatory)]
        [string]$ProfileDirectory,
        [switch]$Incognito
    )

    Focus-Workspace $Workspace
    Start-Sleep -Milliseconds 500

    $argumentList = @(
        "--profile-directory=`"$ProfileDirectory`""
        "--new-window"
    )
    if ($Incognito) {
        $argumentList += "--incognito"
    }

    Start-Process -FilePath $chrome -ArgumentList $argumentList
    Start-Sleep -Milliseconds 1500
}

Start-ChromeOnWorkspace -Workspace "1" -ProfileDirectory "Default"
Start-ChromeOnWorkspace -Workspace "9" -ProfileDirectory "Profile 4"
Start-ChromeOnWorkspace -Workspace "10" -ProfileDirectory "Profile 3"
