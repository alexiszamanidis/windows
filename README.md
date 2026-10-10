## Windows

This repository installs Windows applications.

### Installation

```
irm https://raw.githubusercontent.com/alexiszamanidis/windows/master/install.ps1 | iex
```

### Tasks

The installer runs every task unless you name a subset. Separate names with a comma.

```
.\install.ps1 Packages
.\install.ps1 DarkMode,Wallpaper,Explorer,LongPaths
```

`DarkMode`, `Wallpaper`, `Explorer` and `LongPaths` change Windows settings. `Git` sets the name, email, pull rebase, default branch and fetch prune. The credential helper is `manager`. `Packages` installs the WinGet packages. `InputLeap` copies the server layout and starts the server at login. Desktop is on the left and the Linux client is on the right. `Wsl`, `Font` and `Terminal` set up Ubuntu, Hack Nerd Font Mono and Windows Terminal. Long paths and the Git identity are applied when Git is already installed.

The one-liner runs every task. Set `WINDOWS_TASKS` to the same comma-separated list to run a subset.

### Terminal

The installer downloads Hack Nerd Font Mono and writes Windows Terminal settings. Ansible installs the same font family inside Linux. The default profile is the Ubuntu distro that is installed.

### WSL

The installer enables WSL2 and installs Ubuntu. It does not install Linux packages. If Windows asks for a restart, run the installer again after the restart. Open Ubuntu, create your Linux user, then run the Ansible installer:

```
git clone https://github.com/alexiszamanidis/ansible.git ~/ansible && cd ~/ansible && git remote set-url origin git@github.com:alexiszamanidis/ansible.git && ./install
```
