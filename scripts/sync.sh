#!/usr/bin/env bash
# make sync - fetches teammates' newest records (fast-forward only). Changes your working tree
# only by fast-forwarding; refuses if you are on the wrong branch, have unsaved ledger changes,
# or have unpushed commits. There is no way to skip these checks.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/ledger.sh"
need_config
if [[ "$COORDINATION" == local ]]; then info "COORDINATION=local: there is nothing to sync."; exit 0; fi
ledger_precheck || exit 1
info "Shared records are up to date on branch $GIT_BRANCH."
