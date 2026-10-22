#!/usr/bin/env bash
# Gmail notification content and local reminder checks; all mail is dry-run, all AWS is mocked.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

enable_notifications() {
  cfg_set GMAIL_ADDRESS twinlab-sender@example.com
  cfg_set NOTIFY_EMAILS alice@example.com,bob@example.com,supervisor@example.com
  cfg_set OPERATOR_EMAIL alice@example.com
  mkdir -p "$SB/home/.config/twinlab-ops"
  printf 'test-app-password\n' > "$SB/home/.config/twinlab-ops/gmail-app-password"
  chmod 600 "$SB/home/.config/twinlab-ops/gmail-app-password"
}

echo "[email test command]"
new_sandbox; enable_notifications
begin "make notify-test renders a team email without AWS or Git calls"
tw make notify-test
assert_rc 0; assert_text "PREVIEW: Gmail email not sent."
assert_text "TwinLab email notification test"
assert_text "To: alice@example.com, bob@example.com, supervisor@example.com"
assert_text "No AWS operation was performed."
assert_eq "$(wc -l <"$SB/mock.log" | tr -d ' ')" "0" "test email makes no AWS calls"

new_sandbox; enable_notifications
cfg_set EMAIL_NOTIFICATIONS off
begin "disabled email setting suppresses operation emails and reminders"
TW_INPUT=$'yes\n'; tw scripts/start.sh
assert_rc 0; assert_text "Email notifications are disabled"
assert_no_text "PREVIEW: Gmail email not sent."
assert_not_called "smtp.gmail.com"

begin "notify-test explains that email is disabled"
tw make notify-test
assert_rc 2; assert_text "Email notifications are disabled"

new_sandbox; enable_notifications
cfg_set REMINDER_BACKEND windows
cfg_set REMINDER_MINUTES 5
cat > "$SB/mockbin/wslpath" <<'EOF'
#!/usr/bin/env bash
printf 'C:\\TwinLab\\scripts\\windows\\reminder-task.ps1\n'
EOF
cat > "$SB/mockbin/powershell.exe" <<'EOF'
#!/usr/bin/env bash
printf 'powershell %s\n' "$*" >> "$MOCK_LOG"
EOF
chmod +x "$SB/mockbin/wslpath" "$SB/mockbin/powershell.exe"
begin "Windows reminder registration calls Task Scheduler with the configured WSL distro"
tw bash -c 'source scripts/lib/common.sh; source scripts/lib/notify.sh; need_config; TWINLAB_TEST_SANDBOX=0 WSL_DISTRO_NAME=Ubuntu schedule_start_reminder op-test-1 2026-10-18T14:11:07+00:00'
assert_rc 0; assert_text "Windows reminder is scheduled"
assert_called "powershell -NoProfile -ExecutionPolicy Bypass"
assert_called "-Mode Register"
assert_called "-Distro Ubuntu"
assert_called "-ReminderMinutes 5"
assert_not_called "aws "

begin "notifications refuse a password file readable by other users"
chmod 644 "$SB/home/.config/twinlab-ops/gmail-app-password"
tw make notify-test
assert_rc 2; assert_text "must be private (chmod 600)"
assert_not_called "aws "

echo "[start/stop event notifications]"
new_sandbox; enable_notifications
begin "successful start notifies team with instance details and schedules a local reminder"
cfg_set REMINDER_MINUTES 5
TW_INPUT=$'yes\n'; tw scripts/start.sh
assert_rc 0; assert_text "PREVIEW: Gmail email not sent."
assert_text "TwinLab instance STARTED"; assert_text "Instance: i-0123456789abcdef0"
assert_text "Instance type: t3.small"; assert_text "Observed state: running"
assert_text "Public IP: 203.0.113.10"; assert_text "To: alice@example.com, bob@example.com, supervisor@example.com"
assert_text "TEST: would schedule a 5-minute local reminder for alice@example.com"
assert_not_called "smtp.gmail.com"; assert_never_destructive

new_sandbox; enable_notifications; MOCK_ENV=(MOCK_FAIL_START=1)
begin "failed start does not send a success email or schedule a reminder"
TW_INPUT=$'yes\n'; tw scripts/start.sh
assert_rc 1; assert_no_text "PREVIEW: Gmail email not sent."
assert_no_text "would schedule a 5-minute reminder"

new_sandbox; enable_notifications; set_state running
begin "successful stop notifies team after recording the stop"
TW_INPUT=$'STOP\n'; tw scripts/stop.sh
assert_rc 0; assert_text "PREVIEW: Gmail email not sent."
assert_text "TwinLab instance STOPPED"; assert_text "Observed state: stopped"
assert_text "Instance type: t3.small"; assert_text "To: alice@example.com, bob@example.com, supervisor@example.com"
assert_not_called "smtp.gmail.com"

echo "[running-time reminder]"
new_sandbox; enable_notifications; set_state running
begin "reminder emails only the operator when the same AWS launch is still running"
cfg_set REMINDER_MINUTES 5
tw scripts/reminder.sh op-test-123 "2026-10-17T10:00:00+00:00"
assert_rc 0; assert_text "PREVIEW: Gmail email not sent."
assert_text "TwinLab instance has been running for 5 minutes"
assert_text "To: alice@example.com"; assert_text "Instance type: t3.small"
assert_text "Running-time reminder sent"; assert_not_called "smtp.gmail.com"

begin "old reminder is discarded after a new AWS launch"
tw scripts/reminder.sh op-test-old "2026-10-16T10:00:00+00:00"
assert_rc 0; assert_text "Reminder cancelled"; assert_no_text "PREVIEW: Gmail email not sent."

begin "reminder is discarded when the instance is stopped"
set_state stopped
tw scripts/reminder.sh op-test-stopped "2026-10-17T10:00:00+00:00"
assert_rc 0; assert_text "Reminder cancelled"; assert_no_text "PREVIEW: Gmail email not sent."

finish_tests
