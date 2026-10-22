#!/bin/bash
# Run the offline tests: lint, B1 (classifier), B2 (sandboxed watcher). B3 needs root + systemd-nspawn + a
# debootstrapped root: sudo tests/b3_units_nspawn.sh ROOT  (see that file).
cd "$(dirname "$0")" || exit 1
rc=0
export PYTHONDONTWRITEBYTECODE=1
./lint_no_pkill.sh || rc=1
python3 b1_vrclass_test.py | tail -1; [ "${PIPESTATUS[0]}" = 0 ] || rc=1
./b2_yield_sandbox_test.sh 2>/dev/null | grep -E '^(FAIL|B2)'; [ "${PIPESTATUS[0]}" = 0 ] || rc=1
exit $rc
