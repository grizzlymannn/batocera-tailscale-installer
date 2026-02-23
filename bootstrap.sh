#!/bin/bash
set -e

REPO="grizzlymann/batocera-tailscale-installer"
PACKAGE="batocera-tailscale-installer-latest.tar.gz"

TMPDIR=$(mktemp -d)
cd "$TMPDIR"

curl -L "https://github.com/$REPO/releases/latest/download/$PACKAGE" -o "$PACKAGE"

tar -xzf "$PACKAGE"
cd batocera-tailscale-installer

bash install.sh