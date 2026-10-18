#!/usr/bin/env bash
# make start - starts the shared instance. CHANGES AWS.
# Order: read AWS -> confirm -> claim (published) -> re-check -> start -> verify -> record.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/ledger.sh"
need_config; require_operator
ACTION=start; OP_ID="$(new_op_id)"; HOST="$(hostname 2>/dev/null || echo unknown)"; CALLER_ARN=unknown

read_instance || die 1 "Cannot read the instance state from AWS: $LAST_AWS_ERROR"
print_instance_summary
case "$AWS_STATE" in
  running)
    last="$(ledger last-start)"
    info "The instance is already running. No start request was sent."
    info "Last tracked start: $last"
    [[ "$last" == none ]] && info "(No tracked start found: it may have been started outside these tools. See: make recover)"
    exit 0;;
  stopped) ;;
  *) die 1 "The instance is '$AWS_STATE'. Wait until it is 'stopped', then try again. No request was sent.";;
esac

resolve_caller
info
info "About to START $INSTANCE_ID as type $AWS_TYPE. Compute billing starts while it runs."
info "Operator (self-declared, not verified): $OPERATOR"
confirm "Type 'yes' to start the instance:" yes || { info "Cancelled. Nothing was changed."; exit 1; }

ledger_acquire start observed_state="$AWS_STATE" instance_type="$AWS_TYPE" aws_caller_arn="$CALLER_ARN" || exit 1

# We now hold the claim. Look at AWS again before acting: the state may have changed while we waited.
read_instance || fail_op "Could not re-read the instance after claiming: $LAST_AWS_ERROR"
if [[ "$AWS_STATE" == running ]]; then
  info "The instance became running in the meantime. No start request sent."
  finish_op already 0 "became running before our request"
fi
[[ "$AWS_STATE" == stopped ]] || fail_op "Instance state changed to '$AWS_STATE' after the claim; no start request sent."

info "Sending start request (it is never retried automatically)..."
if ! out="$(aws_cmd ec2 start-instances --instance-ids "$INSTANCE_ID" 2>&1)"; then
  etxt="$(sanitize <<<"$out" | head -c 400)"
  warn "start-instances reported an error: $etxt"
  read_instance || true
  case "${AWS_STATE:-}" in
    pending|running) warn "AWS now shows '$AWS_STATE', so the request did take effect. Verifying.";;
    *) fail_op "start-instances failed: $etxt";;
  esac
fi

info "Waiting up to ${WAIT_TIMEOUT_SECONDS}s for state 'running'..."
if wait_for_state running; then
  info "Verified: the instance is running ($AWS_TYPE)."
  info "DCV can need another minute before it accepts logins. Use: make dcv"
  finish_op success 0 "" aws_launch_time="$AWS_LAUNCH"
else
  read_instance || true
  err "Timed out after ${WAIT_TIMEOUT_SECONDS}s. Last observed state: '${AWS_STATE:-unknown}'. The request may still complete: check make status."
  finish_op timeout 4 "timed out waiting for running (last state ${AWS_STATE:-unknown})"
fi
