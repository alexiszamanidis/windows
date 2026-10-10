## Windows

This repository installs Windows applications.

### Installation

```
irm https://raw.githubusercontent.com/alexiszamanidis/windows/master/install.ps1 | iex
```

### WSL

The installer enables WSL2 and installs Ubuntu. It does not install Linux packages. If Windows asks for a restart, run the installer again after the restart. Open Ubuntu, create your Linux user, then run the Ansible installer:

```
git clone https://github.com/alexiszamanidis/ansible.git ~/ansible && cd ~/ansible && git remote set-url origin git@github.com:alexiszamanidis/ansible.git && ./install
```
