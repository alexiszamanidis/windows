# Windows Terminal builds each WSL profile GUID as a UUIDv5 of the distro name.
# The namespace is Terminal's own. Ubuntu resolves to {2c4de342-38b7-51cf-b940-2309a097f518}.
function Get-WslTerminalProfileGuid {
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )

    $namespace = [guid]"2bde4a90-d05f-401c-9492-e40884ead1d8"
    $namespaceBytes = $namespace.ToByteArray()
    $buffer = [System.Collections.Generic.List[byte]]::new()
    foreach ($index in 3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15) {
        $buffer.Add([byte]$namespaceBytes[$index])
    }
    foreach ($nameByte in [System.Text.Encoding]::Unicode.GetBytes($DistroName)) {
        $buffer.Add([byte]$nameByte)
    }

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha1.ComputeHash($buffer.ToArray())
    } finally {
        $sha1.Dispose()
    }

    $hash[6] = [byte](($hash[6] -band 0x0F) -bor 0x50)
    $hash[8] = [byte](($hash[8] -band 0x3F) -bor 0x80)

    $guidBytes = [System.Collections.Generic.List[byte]]::new()
    foreach ($index in 3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15) {
        $guidBytes.Add([byte]$hash[$index])
    }

    return "{" + ([guid]::new($guidBytes.ToArray())).ToString() + "}"
}

function Install-HackNerdFont {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $fontDirectory = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
    if (-not $PSCmdlet.ShouldProcess($fontDirectory, "Install Hack Nerd Font Mono")) {
        return
    }

    New-Item -ItemType Directory -Path $fontDirectory -Force | Out-Null
    $registryPath = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
    if (-not (Test-Path $registryPath)) {
        New-Item -Path $registryPath -Force | Out-Null
    }

    if (-not ([System.Management.Automation.PSTypeName]"WindowsSetup.FontNativeMethods").Type) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace WindowsSetup {
    public static class FontNativeMethods {
        [DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern int AddFontResource(string fileName);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    }
}
"@
    }

    $styles = @(
        @{ File = "HackNerdFontMono-Regular.ttf"; Name = "Hack Nerd Font Mono Regular (TrueType)" }
        @{ File = "HackNerdFontMono-Bold.ttf"; Name = "Hack Nerd Font Mono Bold (TrueType)" }
        @{ File = "HackNerdFontMono-Italic.ttf"; Name = "Hack Nerd Font Mono Italic (TrueType)" }
        @{ File = "HackNerdFontMono-BoldItalic.ttf"; Name = "Hack Nerd Font Mono Bold Italic (TrueType)" }
    )

    foreach ($style in $styles) {
        $destination = Join-Path $fontDirectory $style.File
        if (-not (Test-Path -LiteralPath $destination)) {
            $fontUri = "https://raw.githubusercontent.com/ryanoasis/nerd-fonts/master/patched-fonts/Hack/$($style.File)"
            Invoke-WebRequest -Uri $fontUri -OutFile $destination -UseBasicParsing
        }
        if ((Get-Item -LiteralPath $destination).Length -eq 0) {
            throw "Font file $destination is empty."
        }

        New-ItemProperty -Path $registryPath -Name $style.Name -PropertyType String -Value $destination -Force | Out-Null
        [void][WindowsSetup.FontNativeMethods]::AddFontResource($destination)
    }

    $broadcastResult = [IntPtr]::Zero
    [void][WindowsSetup.FontNativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 5000, [ref]$broadcastResult)
    Write-Information "Hack Nerd Font Mono installed."
}

function Get-WindowsTerminalSettingsPath {
    $packagesRoot = Join-Path $env:LOCALAPPDATA "Packages"
    $knownFamily = Join-Path $packagesRoot "Microsoft.WindowsTerminal_8wekyb3d8bbwe"
    if (Test-Path $knownFamily) {
        return Join-Path $knownFamily "LocalState\settings.json"
    }

    if (Test-Path $packagesRoot) {
        $family = Get-ChildItem -Path $packagesRoot -Directory -Filter "Microsoft.WindowsTerminal_*" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike "*Preview*" } |
            Select-Object -First 1
        if ($family) {
            return (Join-Path $family.FullName "LocalState\settings.json")
        }
    }

    return Join-Path $knownFamily "LocalState\settings.json"
}

function Set-WindowsTerminalSetting {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $settingsPath = Get-WindowsTerminalSettingsPath
    if (-not $PSCmdlet.ShouldProcess($settingsPath, "Write Windows Terminal settings")) {
        return
    }

    $templatePath = if ($installerRoot) {
        Join-Path $installerRoot "config\terminal-settings.json"
    }
    if (-not ($templatePath -and (Test-Path -LiteralPath $templatePath))) {
        $templatePath = Join-Path $env:TEMP "windows-terminal-settings.json"
        Invoke-WebRequest -Uri "$repoRawBase/$repoRef/config/terminal-settings.json" -OutFile $templatePath -UseBasicParsing
    }

    $distroName = Get-PreferredWslDistroName
    $profileGuid = Get-WslTerminalProfileGuid -DistroName $distroName
    $settings = [System.IO.File]::ReadAllText($templatePath)
    $settings = $settings.Replace("__WSL_DISTRO__", $distroName).Replace("__WSL_GUID__", $profileGuid.Trim("{}"))
    if ($settings.Contains("__WSL_")) {
        throw "Windows Terminal settings still contain an unreplaced placeholder."
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $settingsPath) -Force | Out-Null
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($settingsPath, $settings, $utf8)
    Write-Information "Windows Terminal settings written for $distroName."
}
