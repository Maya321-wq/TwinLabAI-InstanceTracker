#!/usr/bin/env bash
# make history - shows the local copy of the records. READ-ONLY, no network, no Git changes.
# (Run 'make sync' first to fetch teammates' newest records.)
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/ledger.sh"
need_config
ledger history "$@"
if [[ -f runtime/runtime-history.csv ]]; then
  echo
  echo "Legacy records from the old Makefile (runtime/runtime-history.csv, read-only):"
  sanitize <runtime/runtime-history.csv | sed 's/^/  /'
fi
