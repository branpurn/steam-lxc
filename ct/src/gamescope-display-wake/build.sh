#!/bin/bash
# Build and install /usr/local/bin/gamescope-display-wake (needs wayland, base-devel). Run as root in the CT.
set -euo pipefail
cd "$(dirname "$0")"; b=$(mktemp -d)
wayland-scanner client-header gamescope-control.xml "$b/gamescope-control-client-protocol.h"
wayland-scanner private-code gamescope-control.xml "$b/gamescope-control-protocol.c"
cc -O2 -Wall -I"$b" gamescope-display-wake.c "$b/gamescope-control-protocol.c" -lwayland-client -o "$b/gamescope-display-wake"
install -m 755 "$b/gamescope-display-wake" /usr/local/bin/gamescope-display-wake
rm -rf "$b"
