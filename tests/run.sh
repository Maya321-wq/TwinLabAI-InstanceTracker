#!/usr/bin/env bash
# make test - runs every tests/test_*.sh. MOCK-ONLY: no AWS, no remote Git.
# (One test uses a real local git with a bare repo inside a temp dir to reproduce a push race.)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0; total=0
for t in "$here"/test_*.sh; do
  total=$((total+1))
  echo "=== $(basename "$t")"
  bash "$t" || failed=$((failed+1))
done
echo
if (( failed == 0 )); then echo "ALL $total TEST FILES PASSED"; exit 0; fi
echo "$failed of $total TEST FILES FAILED"; exit 1
