#!/bin/bash
# Optional: force a Steam Play compatibility tool for one app (Steam's CompatToolMapping in config.vdf),
# e.g. when a game only works on a specific Proton. Stops the session first (Steam rewrites config.vdf on exit),
# keeps a backup, restarts the session. Steam stays signed in.
# Usage: 70-compat-tool.sh <appid> <tool internal name>   e.g. 70-compat-tool.sh 12345 proton-stable
set -euo pipefail
APP=${1:?appid}; TOOL=${2:?tool name (e.g. proton-stable, proton_experimental)}
[ -r /etc/default/steam-lxc ] && . /etc/default/steam-lxc
U=${STEAM_LXC_USER:-steam}; H=$(getent passwd "$U" | cut -d: -f6)
CFG="$H/.local/share/Steam/config/config.vdf"
active=$(systemctl is-active steamos-session || true)
systemctl stop steamos-session steamos-desktop-session 2>/dev/null || true
cp -a "$CFG" "$CFG.bak-$(date +%Y%m%d-%H%M%S)"
runuser -u "$U" -- python3 - "$CFG" "$APP" "$TOOL" <<'PY'
import sys, re
p, app, tool = sys.argv[1:]
s = open(p).read(); L = s.split("\n")
entry = lambda ind: [ind+f'"{app}"', ind+'{', ind+f'\t"name"\t\t"{tool}"', ind+'\t"config"\t\t""', ind+'\t"priority"\t\t"250"', ind+'}']
idx = next((k for k, l in enumerate(L) if l.strip() == '"CompatToolMapping"'), None)
if idx is None:
    i = next(k for k, l in enumerate(L) if l.strip() == '"Valve"')
    j = next(k for k in range(i+1, len(L)) if L[k].strip() == '"Steam"')
    ind = L[j][:len(L[j]) - len(L[j].lstrip())] + "\t"
    L[j+2:j+2] = [ind+'"CompatToolMapping"', ind+'{'] + entry(ind+"\t") + [ind+'}']
else:
    ind = L[idx][:len(L[idx]) - len(L[idx].lstrip())]
    end = next(k for k in range(idx+2, len(L)) if L[k] == ind+'}')
    # drop an existing entry for this app
    k = idx + 2
    while k < end:
        if L[k].strip() == f'"{app}"':
            e2 = next(m for m in range(k+1, end) if L[m] == L[k][:len(L[k])-len(L[k].lstrip())]+'}')
            del L[k:e2+1]; end -= (e2+1-k)
        else: k += 1
    L[idx+2:idx+2] = entry(ind+"\t")
open(p, "w").write("\n".join(L))
print(f"CompatToolMapping: {app} -> {tool}")
PY
[ "$active" = active ] && systemctl start steamos-session || true
