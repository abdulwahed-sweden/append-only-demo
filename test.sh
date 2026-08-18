#!/bin/sh
# The rule, asserted.
#   ./test.sh             the repair          — 7 of 7 pass
#   ./test.sh --no-guard  without the grants  — stops at the first failure
cd "$(dirname "$0")"
. ./db.sh
run schema.sql
if [ "${1:-}" = "--no-guard" ]; then
    echo "--- running WITHOUT the append-only grants ---"
    run no-guard.sql
fi
run test.sql
