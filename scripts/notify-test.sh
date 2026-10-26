#!/usr/bin/env bash
# Send a test email to the configured team without making AWS or Git calls.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/notify.sh"
need_config
[[ "$EMAIL_NOTIFICATIONS" == on ]] || die 2 "Email notifications are disabled; set EMAIL_NOTIFICATIONS=on to test delivery."
notification_setup_status || die 2 "Gmail notifications not ready: $NOTIFICATION_ERROR"
send_notification_test || die 1 "Test email could not be delivered."
