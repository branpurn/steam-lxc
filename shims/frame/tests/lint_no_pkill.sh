#!/bin/bash
# Lint: the shim's code never uses pkill (any form) or killall; process matching is pgrep -x + exe path only.
cd "$(dirname "$0")/.." || exit 1
if rg -n --no-heading -e '^[^#]*\b(pkill|killall)\b' -e '^[^#]*pgrep[^|#]*\s-f\b' bin lib systemd systemd-user install.sh; then
    echo "LINT FAILED"; exit 1
fi
bash -n bin/steam-lxc-steamvr bin/steam-lxc-steamvr-yield bin/steam-lxc-flat lib/*.sh install.sh tests/*.sh || { echo "LINT FAILED (syntax)"; exit 1; }
python3 -c 'import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' bin/steam-lxc-vrclass bin/vrsettings-merge || { echo "LINT FAILED (python)"; exit 1; }
echo "LINT OK"
