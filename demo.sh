#!/bin/sh
# See the failure and the repair.
cd "$(dirname "$0")"
. ./db.sh
run schema.sql
run demo.sql
