#!/usr/bin/env bash
# make stop - stops the shared instance. CHANGES AWS and interrupts every DCV user.
# Works even when no tracking record exists (an untracked session is recorded as such).
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/ledger.sh"
need_config; require_operator
ACTION=stop; OP_ID="$(new_op_id)"; HOST="$(hostname 2>/dev/null || echo unknown)"; CALLER_ARN=unknown

read_instance || die 1 "Cannot read the instance state from AWS: $LAST_AWS_ERROR"
print_instance_summary
case "$AWS_STATE" in
  stopped) info "The instance is already stopped. No stop request was sent."; exit 0;;
  running) ;;
  *) die 1 "The instance is '$AWS_STATE', not 'running'. Wait and check make status. No request was sent.";;
esac

info "Running since (AWS LaunchTime): $AWS_LAUNCH"
ledger claim-show || true
last="$(ledger last-start)"
info "Last tracked start: $last"
extra=()
if [[ "$last" == none ]]; then
  info "NOTE: there is no tracked start record. The instance may have been started outside these tools,"
  info "      or your records are not synced (make sync). You can still stop it; it is recorded as untracked."
  extra+=(note="untracked session: no start record found")
fi

resolve_caller
cat <<'WARN'

!! STOPPING THE SHARED INSTANCE AFFECTS EVERYONE !!
   All teammates' DCV sessions will be disconnected and running programs
   (including simulations) will be interrupted. Unsaved work can be lost.
   Make sure your teammates have agreed.
WARN
info "Operator (self-declared, not verified): $OPERATOR"
confirm "Type STOP (capitals) to stop the instance:" STOP || { info "Cancelled. Nothing was changed."; exit 1; }

ledger_acquire stop observed_state="$AWS_STATE" instance_type="$AWS_TYPE" aws_caller_arn="$CALLER_ARN" || exit 1

read_instance || fail_op "Could not re-read the instance after claiming: $LAST_AWS_ERROR"
if [[ "$AWS_STATE" == stopped ]]; then
  info "The instance stopped in the meantime. No stop request sent."
  finish_op already 0 "stopped before our request" ${extra[@]+"${extra[@]}"}
fi
[[ "$AWS_STATE" == running ]] || fail_op "Instance state changed to '$AWS_STATE' after the claim; no stop request sent."

info "Sending stop request (it is never retried automatically)..."
if ! out="$(aws_cmd ec2 stop-instances --instance-ids "$INSTANCE_ID" 2>&1)"; then
  etxt="$(sanitize <<<"$out" | head -c 400)"
  warn "stop-instances reported an error: $etxt"
  read_instance || true
  case "${AWS_STATE:-}" in
    stopping|stopped) warn "AWS now shows '$AWS_STATE', so the request did take effect. Verifying.";;
    *) fail_op "stop-instances failed: $etxt";;
  esac
fi

info "Waiting up to ${WAIT_TIMEOUT_SECONDS}s for state 'stopped'..."
if wait_for_state stopped; then
  info "Verified: the instance is stopped. (Disks and other resources can still cost money while stopped.)"
  finish_op success 0 "" ${extra[@]+"${extra[@]}"}
else
  read_instance || true
  err "Timed out after ${WAIT_TIMEOUT_SECONDS}s. Last observed state: '${AWS_STATE:-unknown}'. It may still be stopping: check make status."
  finish_op timeout 4 "timed out waiting for stopped (last state ${AWS_STATE:-unknown})" ${extra[@]+"${extra[@]}"}
fi
