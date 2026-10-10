@{
    "9NKSQGP7F2NH" = @{
        Source = "msstore"
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
