# Repository guidelines

-   Change files in this repository. Do not edit `%USERPROFILE%\.glzr`, the registry, or running apps, and do not install software, start or stop apps, or reload GlazeWM or Zebar, unless the user asks for that live change.
-   A live change that can close windows, restart Explorer, or need elevation requires the impact stated and a yes first.
-   `install.ps1` selects tasks. Behavior is in `tasks/`. Values and files copied onto the machine are in `config/`.
-   GlazeWM, Zebar, and the Windows taskbar are different surfaces.
-   For a PowerShell change, run one test: `Invoke-Pester -Path ./tests/install.Tests.ps1 -FullName '<Name>' -Output Detailed`. Do not run the installer.
