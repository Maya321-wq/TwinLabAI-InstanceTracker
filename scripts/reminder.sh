#!/usr/bin/env bash
# Local-only timer for the operator who started the instance.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/notify.sh"
need_config

op_id="${1:-}"
expected_launch="${2:-}"
[[ "$op_id" =~ ^[A-Za-z0-9._-]{1,100}$ && -n "$expected_launch" ]] || die 2 "reminder requires an operation id and AWS launch time"
notification_setup_status || die 2 "reminder not configured: $NOTIFICATION_ERROR"

if [[ "${TWINLAB_TEST_SANDBOX:-}" != 1 ]]; then
  launch_epoch="$(date -u -d "$expected_launch" +%s)" || die 2 "AWS launch time could not be parsed for the reminder"
  deadline=$((launch_epoch + REMINDER_MINUTES * 60))
  now_epoch="$(date -u +%s)" || die 2 "current time could not be read for the reminder"
  delay=$((deadline - now_epoch))
  (( delay > 0 )) && sleep "$delay"
fi

read_instance || die 1 "Reminder could not verify the instance state: $LAST_AWS_ERROR"
if [[ "$AWS_STATE" != running || "$AWS_LAUNCH" != "$expected_launch" ]]; then
  info "Reminder cancelled: the original instance session is no longer running."
  exit 0
fi

if notify_mail reminder start \
  --operator "$OPERATOR" --op-id "$op_id" \
  --instance-id "$INSTANCE_ID" --region "$REGION" \
  --instance-type "$AWS_TYPE" --state "$AWS_STATE" \
  --public-ip "${AWS_IP:-}" --duration-minutes "$REMINDER_MINUTES"; then
  info "Running-time reminder sent to $OPERATOR_EMAIL."
else
  die 1 "Running-time reminder could not be delivered."
fi
