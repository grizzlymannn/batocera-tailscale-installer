#!/bin/bash
set -euo pipefail
clear

REPO="grizzlymannn/batocera-tailscale-installer"
PACKAGE="batocera-tailscale-installer-latest.tar.gz"

need() { command -v "$1" > /dev/null 2>&1 || {
    echo "ERROR: missing required tool: $1" >&2
    exit 1
}; }
need curl
need tar
need mktemp
need bash

TMPDIR=$(mktemp -d)
cleanup() { [[ -d $TMPDIR ]] && rm -rf "$TMPDIR"; }
trap cleanup EXIT

cd "$TMPDIR"

echo "Downloading latest release..."
curl -fL --retry 3 --retry-delay 2 --max-time 60 "https://github.com/$REPO/releases/latest/download/$PACKAGE" -o "$PACKAGE"

if [[ ! -s $PACKAGE ]]; then
    echo "ERROR: download failed or file empty" >&2
    exit 1
fi

echo "Extracting archive..."
tar -xzf "$PACKAGE"

echo "Running installer..."
if [[ ! -f install.sh ]]; then
    echo "ERROR: install.sh not found in extracted directory" >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    if command -v sudo > /dev/null 2>&1; then
        echo "Installer requires root; running with sudo"
        sudo bash install.sh
    else
        echo "Installer requires root. Please re-run as root or install sudo." >&2
        exit 1
    fi
else
    bash install.sh
fi
