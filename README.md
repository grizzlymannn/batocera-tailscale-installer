# Batocera Tailscale Installer

[![Download Latest](https://img.shields.io/badge/Download-Latest%20Release-brightgreen?style=for-the-badge)](https://github.com/grizzlymannn/batocera-tailscale-installer/releases/latest/download/batocera-tailscale-installer-latest.tar.gz)

[![Release](https://img.shields.io/github/v/release/grizzlymannn/batocera-tailscale-installer)](https://github.com/grizzlymannn/batocera-tailscale-installer/releases)
![License](https://img.shields.io/github/license/grizzlymannn/batocera-tailscale-installer)
[![Platform](https://img.shields.io/badge/platform-Batocera-blue)](https://batocera.org)
[![Tailscale](https://img.shields.io/badge/Tailscale-Enabled-00A9E0?logo=tailscale&logoColor=white)](https://tailscale.com)

Lightweight installer, configuration wizard, and monitoring scripts to run Tailscale reliably on Batocera systems.

## Features

- Interactive setup wizard
- Persistent configuration management
- Automatic route and exit-node handling
- Self-healing monitor for network changes
- Minimal footprint — designed for appliance-style systems

## Why?

Batocera is designed as a lightweight, appliance-like OS.  
This project provides a simple, reliable way to install and manage Tailscale without relying on complex distro-specific tooling.

## Installation

Automatic:

```bash
curl -fsSL https://raw.githubusercontent.com/grizzlymannn/batocera-tailscale-installer/main/bootstrap.sh | bash
```

Manual:

```bash
curl -L https://github.com/grizzlymannn/batocera-tailscale-installer/releases/latest/download/batocera-tailscale-installer-latest.tar.gz
tar -xzf batocera-tailscale-installer-latest.tar.gz
cd batocera-tailscale-installer
chmod +x install.sh
./install.sh
```