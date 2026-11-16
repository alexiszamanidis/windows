@{
    "9NKSQGP7F2NH" = @{
        Source = "msstore"
    }
    "Discord.Discord" = @{
        Processes = @(
            "Discord"
        )
        RetryOnShellExec = $true
    }
    "Flow-Launcher.Flow-Launcher" = @{
        Processes = @(
            "Flow.Launcher*"
        )
        RetryOnShellExec = $true
    }
    "input-leap.input-leap" = @{
        Silent = $true
        Custom = "/FORCECLOSEAPPLICATIONS"
        Processes = @(
            "input-leap"
            "input-leapd"
            "input-leapc"
            "input-leaps"
        )
        Service = "InputLeap"
        RetryOnCancel = $true
    }
}
