## Windows

This repository prepares the Windows host. It installs WinGet applications, Windows settings, WSL2 and Ubuntu. Linux packages and dotfiles are installed later, inside Ubuntu, by [Ansible](https://github.com/alexiszamanidis/ansible). Ansible then stows [dotfiles](https://github.com/alexiszamanidis/dotfiles).

### Order

1. Run the installer below.
2. If Windows asks for a restart, restart and run the installer again. The installer does not install Linux packages.
3. Open Ubuntu and create the Linux user.
4. Run the Ansible installer. It prompts for the vault password when needed, then for the sudo password.

```
git clone https://github.com/alexiszamanidis/ansible.git ~/ansible && cd ~/ansible && git remote set-url origin git@github.com:alexiszamanidis/ansible.git && ./install
```

### Installation

```
irm https://raw.githubusercontent.com/alexiszamanidis/windows/HEAD/install.ps1 | iex
```

The URL follows the repository default branch. The one-liner runs every task. Set `WINDOWS_TASKS` to a comma-separated list to run a subset.

### Layout

`install.ps1` stays at the repository root so the one-liner can start it. Task scripts live in `tasks`. Files the installer deploys onto the machine live in `config`.

### What it changes

-   Dark mode for Windows and apps
-   The desktop wallpaper. Span when two or more monitors are connected, fill on one
-   File Explorer shows extensions and hidden files
-   Long paths in Windows and Git `core.longpaths`
-   Git name, email, pull rebase, default branch and fetch prune. The credential helper is `manager`
-   The WinGet packages in `config/packages.txt`
-   Flow Launcher opens with Win+P and starts at login. Win+Shift+P searches open windows. Windows is told to stop using Win+P for the project screen. If Windows still takes Win+P, a login helper opens Flow Launcher instead
-   GlazeWM follows the i3 config: the Windows key, the ten workspaces and the window assignments. A top bar lists the workspaces. Win+P stays with Flow Launcher. GlazeWM starts at login
-   The Input Leap server layout. Desktop is on the left and the Linux client is on the right. The server starts at login
-   WSL2 and one Ubuntu distro
-   Hack Nerd Font Mono and Windows Terminal settings. The default profile is the Ubuntu distro that is installed. Ansible installs the same font family inside Linux

### Packages

`config/packages.txt` is one WinGet package ID per line. Lines starting with `#` are ignored. Installer options that are not the same for every package live in `config/packages.psd1`. WhatsApp is installed from the Microsoft Store source. Input Leap is installed silently, its processes are closed first, and the install is retried once if the installer reports that it was cancelled.

### Tasks

The installer runs every task unless you name a subset. Separate names with a comma. List the names from the script:

```
Select-String -Path .\install.ps1 -Pattern '^\$knownTasks'
```

```
.\install.ps1 Packages
.\install.ps1 DarkMode,Wallpaper,Explorer,LongPaths
```

The task names are `DarkMode`, `Wallpaper`, `Explorer`, `LongPaths`, `Git`, `Packages`, `FlowLauncher`, `GlazeWM`, `InputLeap`, `Wsl`, `Font` and `Terminal`. A file run takes that list as its first argument. A file run needs a process execution policy that allows unsigned scripts: `powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 Packages`. The one-liner cannot take arguments, so set `WINDOWS_TASKS` before running it. Long paths and the Git identity are applied when Git is already installed.
