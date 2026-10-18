#!/usr/bin/env bash
# make clear-claim - removes a STALE (expired) or unreadable claim so work can continue.
# Changes only ledger/ (never AWS). An ACTIVE claim is never cleared.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/ledger.sh"
need_config; require_operator
ACTION=clear-claim; OP_ID="$(new_op_id)"; HOST="$(hostname 2>/dev/null || echo unknown)"

ledger_precheck || exit 1          # fetches the latest shared records first
ledger claim-show; rc=$?
case $rc in
  0) info "There is no claim. Nothing to clear."; exit 0;;
  10) die 1 "That claim is still active (its time limit has not passed). Wait for it or ask that teammate. Nothing was changed.";;
esac
if read_instance; then info "AWS currently reports: $AWS_STATE ($AWS_TYPE)"; else warn "AWS could not be read: $LAST_AWS_ERROR"; fi
info "Check that the interrupted operation is really over before clearing. AWS will NOT be touched."
confirm "Type 'clear' to remove this claim:" clear || { info "Cancelled. Nothing was changed."; exit 1; }

out="$(ledger claim-clear --op-id "$OP_ID" --operator "$OPERATOR" --host "$HOST" instance_id="$INSTANCE_ID" region="$REGION" 2>&1)" \
  || die 1 "$out"
info "$out"
if ! publish "ledger: clear stale claim ($OP_ID) by $OPERATOR"; then
  err "The claim was cleared on this computer but NOT pushed: ${LAST_GIT_ERROR:-see above}"
  err "Run: make recover   (it prints the exact next steps)"
  exit 3
fi
info "Claim cleared and recorded."
