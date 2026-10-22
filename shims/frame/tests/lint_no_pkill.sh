#!/bin/bash
# Lint: the shim's code never uses pkill (any form) or killall; process matching is pgrep -x + exe path only.
cd "$(dirname "$0")/.." || exit 1
if rg -n --no-heading -e '^[^#]*\b(pkill|killall)\b' -e '^[^#]*pgrep[^|#]*\s-f\b' bin lib systemd systemd-user install.sh; then
    echo "LINT FAILED"; exit 1
fi
for f in bin/steam-lxc-steamvr bin/steam-lxc-flat bin/steamvr-setcap lib/*.sh install.sh tests/*.sh; do bash -n "$f" || { echo "LINT FAILED (syntax: $f)"; exit 1; }; done
python3 -c 'import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' bin/steam-lxc-vrclass bin/vrsettings-merge || { echo "LINT FAILED (python)"; exit 1; }
echo "LINT OK"
