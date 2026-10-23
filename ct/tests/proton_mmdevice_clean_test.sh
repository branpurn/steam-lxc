#!/bin/bash
# Offline test for ct/usr/local/bin/proton-mmdevice-clean against ct/tests/fixtures/mmdev-system.reg.
cd "$(dirname "$0")/../.." || exit 1
TOOL=$PWD/ct/usr/local/bin/proton-mmdevice-clean; FIX=$PWD/ct/tests/fixtures/mmdev-system.reg
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; pass=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "ok:   $1"; else fail=$((fail+1)); echo "FAIL: $1"; fi; }
# fake Steam root with a second library from libraryfolders.vdf
P1=$T/steam/steamapps/compatdata/438100/pfx; P2=$T/lib2/steamapps/compatdata/250820/pfx
mkdir -p "$P1" "$P2"; cp "$FIX" "$P1/system.reg"; cp "$FIX" "$P2/system.reg"
printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n' "$T/steam" "$T/lib2" >"$T/steam/steamapps/libraryfolders.vdf"

echo "--- dry run"; "$TOOL" --steam-root "$T/steam" | tee "$T/dry"
ok "dry run finds both library prefixes" '[ "$(grep -c "2 stale" "$T/dry")" = 2 ]'
ok "dry run leaves files untouched" 'cmp -s "$FIX" "$P1/system.reg" && cmp -s "$FIX" "$P2/system.reg"'
ok "dry run reports max name length" 'grep -q "longest stale name 123 chars" "$T/dry"'

echo "--- --max-len 1000 (no-op)"; "$TOOL" --steam-root "$T/steam" --apply --max-len 1000 | tee "$T/ml"
ok "--max-len above longest skips" 'cmp -s "$FIX" "$P1/system.reg" && ! ls "$P1"/system.reg.bak-* 2>/dev/null'

echo "--- apply"; "$TOOL" --steam-root "$T/steam" --apply | tee "$T/apply"
for p in "$P1" "$P2"; do
  ok "stale devices removed ($p)" '! grep -q "1111-111111111111\|3333-333333333333" "$p/system.reg"'
  ok "present/unplugged devices kept" 'grep -q "4444-444444444444" "$p/system.reg" && grep -q "2222-222222222222" "$p/system.reg" && grep -q "5555-555555555555" "$p/system.reg"'
  ok "backup is the original" 'cmp -s "$FIX" "$(ls "$p"/system.reg.bak-mmdev-*)"'
done
# expected = fixture with exactly the stale device sections (header line up to the next blank-preceded header) dropped
awk '/^\[/ && prev=="" {drop = ($0 ~ /(1111-111111111111|3333-333333333333)/)} !drop {print} {prev=$0}' "$FIX" >"$T/exp"
ok "everything outside removed sections is byte-identical" 'cmp "$T/exp" "$P1/system.reg"'
diff <(cat "$FIX") "$P1/system.reg" | grep '^>' && { echo "FAIL: apply added lines"; fail=$((fail+1)); }
echo "--- second apply (idempotent)"; "$TOOL" --steam-root "$T/steam" --apply | tee "$T/a2"
ok "second apply finds nothing" '[ "$(grep -c "0 stale" "$T/a2")" = 2 ]'

echo "--- running wineserver -> skip"; cp "$FIX" "$P1/system.reg"
eval "$(stat -c 'D=%d I=%i' "$P1")"; S=/tmp/.wine-$(id -u)/server-$(printf '%x-%x' "$D" "$I")
mkdir -p "$S"; : >"$S/socket"
"$TOOL" --prefix "$P1" --apply | tee "$T/busy"; rm -rf "$S"
ok "skips prefix with a running wineserver" 'grep -q "skip: wineserver" "$T/busy" && cmp -s "$FIX" "$P1/system.reg"'

echo "--- backups capped at 3"
for i in 1 2 3 4 5; do touch "$P2/system.reg.bak-mmdev-2000010${i}-000000"; done; cp "$FIX" "$P2/system.reg"
"$TOOL" --prefix "$P2" --apply >/dev/null
ok "keeps only the last 3 backups" '[ "$(ls "$P2"/system.reg.bak-mmdev-* | wc -l)" = 3 ]'
echo "passed $pass, failed $fail"; [ "$fail" = 0 ]
