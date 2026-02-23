# Batocera Tailscale Installer

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

Download the latest release:

```bash
wget https://github.com/grizzlymann/batocera-tailscale-installer/releases/latest/download/batocera-tailscale-installer-<version>.tar.gz
tar -xzf batocera-tailscale-installer-*.tar.gz
cd batocera-tailscale-installer
chmod +x install.sh
./install.sh