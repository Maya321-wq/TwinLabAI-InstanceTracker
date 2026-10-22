#!/usr/bin/env bash
# Gmail notification helpers. Source after common.sh has loaded config.

notify_mail() {
  local mode="$1" action="$2" args=()
  shift 2
  if ! notification_setup_status; then
    warn "Gmail notification skipped: $NOTIFICATION_ERROR"
    return 1
  fi
  if [[ "${TWINLAB_TEST_SANDBOX:-}" == 1 ]]; then
    args+=(--preview-kind "$mode")
    mode=preview
  fi
  python3 -I "$TW_TOOLS/notify.py" "$mode" \
    "${args[@]}" \
    --action "$action" --from-address "$GMAIL_ADDRESS" \
    --to "$NOTIFY_EMAILS" --operator-email "$OPERATOR_EMAIL" \
    --password-file "$GMAIL_PASSWORD_FILE" "$@"
}

notify_operation() {
  local action="$1"
  if [[ "$EMAIL_NOTIFICATIONS" == off ]]; then
    info "Email notifications are disabled; no $action email will be sent."
    return 0
  fi
  notify_mail event "$action" \
    --operator "$OPERATOR" --op-id "$OP_ID" \
    --instance-id "$INSTANCE_ID" --region "$REGION" \
    --instance-type "${AWS_TYPE:-unknown}" --state "${AWS_STATE:-unknown}" \
    --public-ip "${AWS_IP:-}" || {
      warn "AWS operation and ledger record remain successful; check Gmail notification setup/delivery."
      return 1
    }
}

send_notification_test() {
  notify_mail test start \
    --operator "$OPERATOR" --op-id "notification-test" \
    --instance-id "$INSTANCE_ID" --region "$REGION" \
    --instance-type "not queried" --state "not queried" --public-ip ""
}

schedule_start_reminder() {
  local op_id="$1" launch_time="$2" log_dir log_file task_script
  if [[ "$EMAIL_NOTIFICATIONS" == off ]]; then
    info "Email notifications are disabled; no running-time reminder will be scheduled."
    return 0
  fi
  notification_setup_status || return 0
  if [[ "${TWINLAB_TEST_SANDBOX:-}" == 1 ]]; then
    info "TEST: would schedule a ${REMINDER_MINUTES}-minute $REMINDER_BACKEND reminder for $OPERATOR_EMAIL"
    return 0
  fi
  if [[ "$REMINDER_BACKEND" == windows ]]; then
    if [[ -z "${WSL_DISTRO_NAME:-}" ]] || ! command -v powershell.exe >/dev/null 2>&1 || ! command -v wslpath >/dev/null 2>&1; then
      warn "Windows reminder requires WSL_DISTRO_NAME, powershell.exe and wslpath; no reminder was scheduled."
      return 1
    fi
    task_script="$(wslpath -w "$TW_ROOT/scripts/windows/reminder-task.ps1")" || {
      warn "Could not convert the Windows reminder script path."
      return 1
    }
    if ! powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$task_script" \
      -Mode Register -Distro "$WSL_DISTRO_NAME" -RepoPath "$TW_ROOT" \
      -OpId "$op_id" -LaunchTime "$launch_time" -ReminderMinutes "$REMINDER_MINUTES"; then
      warn "Windows Task Scheduler could not register the reminder."
      return 1
    fi
    info "A ${REMINDER_MINUTES}-minute Windows reminder is scheduled for $OPERATOR_EMAIL."
    info "Windows will try to wake this PC from sleep and run missed tasks when available."
    return 0
  fi
  log_dir="$HOME/.local/state/twinlab-ops"
  log_file="$log_dir/reminder-$op_id.log"
  if ! mkdir -p "$log_dir"; then
    warn "Could not create the local reminder log directory; no reminder was scheduled."
    return 1
  fi
  if nohup bash "$TW_ROOT/scripts/reminder.sh" "$op_id" "$launch_time" </dev/null >>"$log_file" 2>&1 & then
    info "A ${REMINDER_MINUTES}-minute reminder is scheduled for $OPERATOR_EMAIL."
    info "It runs on this WSL computer; its log is $log_file"
  else
    warn "Could not start the local reminder process."
    return 1
  fi
}
