#!/usr/bin/env bash
# make set-type [TYPE=<type>] - changes the instance type. CHANGES AWS.
# NEVER stops the instance: if it is running this refuses. Never starts it afterwards.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/ledger.sh"
need_config; require_operator
load_allowlist || die 2 "$ALLOWLIST_ERROR"
(( ${#ALLOW_APPROVED[@]} > 0 )) || die 2 "No type is marked 'approved' in config/instance-types.txt. Confirm the list with your supervisor, then change UNCONFIRMED to approved for the types they approved."
ACTION=set-type; OP_ID="$(new_op_id)"; HOST="$(hostname 2>/dev/null || echo unknown)"; CALLER_ARN=unknown

REQ="${TYPE:-}"
if [[ -z "$REQ" ]]; then
  info "Select the target instance type (only approved types can be chosen):"
  n=0
  for t in "${ALLOW_APPROVED[@]}"; do n=$((n+1)); printf '  %d) %s\n' "$n" "$t"; done
  for t in ${ALLOW_PENDING[@]+"${ALLOW_PENDING[@]}"}; do printf '  -  %s  (UNCONFIRMED: not selectable)\n' "$t"; done
  printf 'Enter choice [1-%d]: ' "$n" >&2
  IFS= read -r choice || choice=""
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )) || die 1 "Invalid choice. Nothing was changed."
  REQ="${ALLOW_APPROVED[$((choice-1))]}"
fi

approved=0
for t in "${ALLOW_APPROVED[@]}"; do [[ "$t" == "$REQ" ]] && approved=1; done
if (( approved == 0 )); then
  for t in ${ALLOW_PENDING[@]+"${ALLOW_PENDING[@]}"}; do
    [[ "$t" == "$REQ" ]] && die 1 "'$REQ' is listed but UNCONFIRMED. Get your supervisor's approval, then mark it 'approved' in config/instance-types.txt."
  done
  die 1 "'$REQ' is not in config/instance-types.txt. Only listed, approved types are accepted. Nothing was changed."
fi

read_instance || die 1 "Cannot read the instance from AWS: $LAST_AWS_ERROR"
print_instance_summary
info "Requested: $REQ"
case "$AWS_STATE" in
  stopped) ;;
  running) die 1 "The instance is RUNNING. set-type never stops it as a side effect. Agree with your teammates, run 'make stop', then run this again.";;
  *) die 1 "The instance is '$AWS_STATE'. It must be 'stopped'. Nothing was changed.";;
esac
[[ "$AWS_TYPE" == "$REQ" ]] && { info "The instance is already $REQ. Nothing to do."; exit 0; }

errf="$(mktemp)"
off="$(aws_cmd ec2 describe-instance-type-offerings --location-type availability-zone \
      --filters "Name=instance-type,Values=$REQ" "Name=location,Values=$AWS_AZ" \
      --query 'InstanceTypeOfferings[].InstanceType' --output text 2>"$errf")" \
  || { e="$(sanitize <"$errf" | head -c 300)"; rm -f "$errf"; die 1 "Could not verify that $REQ is offered in $AWS_AZ: $e. Needs human review. Nothing was changed."; }
rm -f "$errf"
[[ "$off" == "$REQ" ]] || die 1 "AWS does not list $REQ in availability zone ${AWS_AZ:-?} of $REGION. Needs human review. Nothing was changed."

resolve_caller
info
info "About to change the type of $INSTANCE_ID:  $AWS_TYPE  ->  $REQ   (instance stays STOPPED)"
info "Please read:"
info "  * This tool CANNOT check that your AMI, drivers and software work on $REQ."
[[ "$AWS_TYPE" == g4dn.* && "$REQ" != g4dn.* ]] && info "  * Moving from g4dn to $REQ removes the GPU: CARLA and other GPU software will not work."
[[ "$AWS_TYPE" != g4dn.* && "$REQ" == g4dn.* ]] && info "  * g4dn has an NVIDIA GPU: the NVIDIA driver (and CARLA) must be installed on the machine image."
info "  * The public IP (and DCV URL) can change on the next start unless an Elastic IP is attached."
info "  * Capacity for $REQ is not guaranteed: the next 'make start' can fail with a capacity error."
info "Operator (self-declared, not verified): $OPERATOR"
confirm "Type 'yes' to change the instance type:" yes || { info "Cancelled. Nothing was changed."; exit 1; }

ledger_acquire set-type observed_state="$AWS_STATE" instance_type="$AWS_TYPE" requested_type="$REQ" aws_caller_arn="$CALLER_ARN" || exit 1

read_instance || fail_op "Could not re-read the instance after claiming: $LAST_AWS_ERROR"
[[ "$AWS_STATE" == stopped ]] || fail_op "Instance state is now '$AWS_STATE' (must be stopped); type NOT changed."
[[ "$AWS_TYPE" == "$REQ" ]] && { info "Type already $REQ."; finish_op already 0 "type already requested" requested_type="$REQ"; }

info "Submitting type change (not retried automatically)..."
if ! out="$(aws_cmd ec2 modify-instance-attribute --instance-id "$INSTANCE_ID" --instance-type "Value=$REQ" 2>&1)"; then
  etxt="$(sanitize <<<"$out" | head -c 400)"
  warn "modify-instance-attribute reported an error: $etxt"
  read_instance || true
  [[ "${AWS_TYPE:-}" == "$REQ" ]] || fail_op "modify-instance-attribute failed: $etxt"
fi

ok=0
for i in 1 2 3 4 5; do
  if read_instance && [[ "$AWS_TYPE" == "$REQ" ]]; then ok=1; break; fi
  (( i < 5 )) && sleep "$POLL_SECONDS"
done
if (( ok == 1 )); then
  info "Verified: instance type is now $AWS_TYPE. The instance is still $AWS_STATE. Start it with: make start"
  finish_op success 0 "" requested_type="$REQ"
fi
err "AWS did not report type $REQ after the change (it reports '${AWS_TYPE:-unknown}'). Needs human review."
finish_op failed 1 "type after change is '${AWS_TYPE:-unknown}', expected $REQ" requested_type="$REQ"
