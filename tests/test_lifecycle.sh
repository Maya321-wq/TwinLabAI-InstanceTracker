#!/usr/bin/env bash
# start / stop / set-type against the fake aws + fake git (COORDINATION=git, so the claim path is exercised).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

lineno()   { grep -nF -- "$1" "$SB/mock.log" | sed -n "${2:-1}p" | cut -d: -f1; }
count_log(){ grep -cF -- "$1" "$SB/mock.log" | tr -d ' '; }
has_event(){ grep -rlF "\"$1\": \"$2\"" "$TW_DIR/ledger/events" >/dev/null 2>&1; }
assert_event() { has_event "$1" "$2" && _ok "event has $1=$2" || _bad "no event with $1=$2"; }
no_aws() { assert_eq "$(grep -c '^aws ' "$SB/mock.log" | tr -d ' ')" "0" "no AWS call made"; }

echo "[start]"
new_sandbox; begin "already running: no start request, exit 0"
set_state running; tw scripts/start.sh
assert_rc 0; assert_text "already running"; assert_not_called "start-instances"; assert_not_called "git push"; assert_eq "$(count_events)" "0" "nothing recorded"

new_sandbox; begin "pending/stopping: refused without any request"
set_state stopping; tw scripts/start.sh
assert_rc 1; assert_text "Wait until it is 'stopped'"; assert_not_called "start-instances"

new_sandbox; begin "declined (typing 'no'), and EOF on stdin, change nothing"
TW_INPUT=$'no\n'; tw scripts/start.sh
assert_rc 1; assert_text "Cancelled"; assert_not_called "start-instances"; assert_not_called "git push"; assert_eq "$(count_events)" "0" "nothing recorded"
TW_INPUT=""; tw scripts/start.sh; assert_rc 1; assert_not_called "start-instances"

new_sandbox; begin "accepted: claim is pushed BEFORE AWS is called, result verified, claim released"
TW_INPUT=$'yes\n'; tw scripts/start.sh
assert_rc 0; assert_text "Verified: the instance is running"
assert_eq "$(count_log 'start-instances')" "1" "exactly one start request"
assert_eq "$(cat "$SB/mock/state")" "running" "mock AWS really is running"
p1="$(lineno 'git push' 1)"; s="$(lineno 'start-instances' 1)"; p2="$(lineno 'git push' 2)"
[[ -n "$p1" && -n "$s" && -n "$p2" && "$p1" -lt "$s" && "$s" -lt "$p2" ]] && _ok "order: push(claim) < start-instances < push(result)" || _bad "wrong order" "p1=$p1 s=$s p2=$p2"
assert_eq "$(count_events)" "2" "intent + result events"
assert_event outcome success; assert_event operator_declared alice; grep -rqF '"operator_verified": false' "$TW_DIR/ledger/events" && _ok "events say operator_verified=false" || _bad "operator_verified=false missing"
assert_event aws_caller_arn "arn:aws:iam::123456789012:user/shared-mock"
assert_no_file "$TW_DIR/ledger/claim.json"
assert_not_called "git push --force"; assert_never_destructive
tw scripts/history.sh; assert_text "still open: no stop recorded yet"; assert_text "SELF-DECLARED"

new_sandbox; begin "waiter that never completes: exit 4, timeout recorded, claim released"
MOCK_ENV=(MOCK_NEVER_COMPLETE=1); TW_INPUT=$'yes\n'; tw scripts/start.sh
assert_rc 4; assert_text "Timed out"; assert_event outcome timeout; assert_no_file "$TW_DIR/ledger/claim.json"
assert_eq "$(count_log 'start-instances')" "1" "start request was not retried"

new_sandbox; begin "AWS refuses the start: exit 1, failure recorded, key id never stored"
MOCK_ENV=(MOCK_FAIL_START=1); TW_INPUT=$'yes\n'; tw scripts/start.sh
assert_rc 1; assert_event outcome failed; assert_no_file "$TW_DIR/ledger/claim.json"; assert_no_text "AKIAABCDEFGHIJKLMNOP"
grep -rq "AKIA" "$TW_DIR/ledger" && _bad "key id leaked into the ledger" || _ok "no key id in ledger files"

new_sandbox; begin "error reply but the request DID take effect: verified, not retried"
MOCK_ENV=(MOCK_START_APPLY_BUT_ERROR=1); TW_INPUT=$'yes\n'; tw scripts/start.sh
assert_rc 0; assert_text "did take effect"; assert_eq "$(count_log 'start-instances')" "1" "not retried"; assert_event outcome success

echo "[stop]"
new_sandbox; begin "already stopped: no request"
tw scripts/stop.sh; assert_rc 0; assert_text "already stopped"; assert_not_called "stop-instances"

new_sandbox; begin "declined, or typed 'yes' instead of STOP: nothing changes; warning is shown"
set_state running; TW_INPUT=$'no\n'; tw scripts/stop.sh
assert_rc 1; assert_text "AFFECTS EVERYONE"; assert_text "DCV"; assert_not_called "stop-instances"; assert_eq "$(count_events)" "0" "nothing recorded"
TW_INPUT=$'yes\n'; tw scripts/stop.sh; assert_rc 1; assert_not_called "stop-instances"
assert_eq "$(cat "$SB/mock/state")" "running" "instance still running"

new_sandbox; begin "running with NO tracking record can still be stopped (recorded as untracked)"
set_state running; TW_INPUT=$'STOP\n'; tw scripts/stop.sh
assert_rc 0; assert_text "no tracked start"; assert_text "Verified: the instance is stopped"
assert_eq "$(count_log 'stop-instances')" "1" "one stop request"; assert_eq "$(cat "$SB/mock/state")" "stopped" "mock AWS stopped"
assert_event note "untracked session: no start record found"; assert_event outcome success; assert_no_file "$TW_DIR/ledger/claim.json"
tw scripts/history.sh; assert_text "no tracked start"

new_sandbox; begin "stop that never completes: exit 4"
set_state running; MOCK_ENV=(MOCK_NEVER_COMPLETE=1); TW_INPUT=$'STOP\n'; tw scripts/stop.sh
assert_rc 4; assert_text "Timed out"; assert_event outcome timeout

new_sandbox; begin "AWS refuses the stop: exit 1, instance still running, failure recorded"
set_state running; MOCK_ENV=(MOCK_FAIL_STOP=1); TW_INPUT=$'STOP\n'; tw scripts/stop.sh
assert_rc 1; assert_event outcome failed; assert_eq "$(cat "$SB/mock/state")" "running" "still running"

new_sandbox; begin "start then stop: history shows one session by alice"
TW_INPUT=$'yes\n'; tw scripts/start.sh; TW_INPUT=$'STOP\n'; tw scripts/stop.sh; assert_rc 0
tw scripts/history.sh; assert_text "start:alice stop:alice"; assert_eq "$(count_events)" "4" "two intents + two results"

echo "[set-type]"
new_sandbox; begin "approved type while stopped: changed, verified, still stopped, never stopped/started"
TW_INPUT=$'yes\n'; tw env TYPE=t3.medium scripts/set-type.sh
assert_rc 0; assert_text "Verified: instance type is now t3.medium"; assert_eq "$(cat "$SB/mock/type")" "t3.medium" "type changed"
assert_called "modify-instance-attribute"; assert_not_called "stop-instances"; assert_not_called "start-instances"
assert_eq "$(cat "$SB/mock/state")" "stopped" "still stopped"; assert_event requested_type t3.medium; assert_event outcome success
assert_no_file "$TW_DIR/ledger/claim.json"; assert_never_destructive

new_sandbox; begin "unapproved or unknown type is rejected before any AWS call"
tw env TYPE=m5.large scripts/set-type.sh; assert_rc 1; assert_text "not in config/instance-types.txt"; no_aws
tw env TYPE=g5.xlarge scripts/set-type.sh; assert_rc 1; assert_text "not in config/instance-types.txt"; no_aws

new_sandbox; begin "UNCONFIRMED type is rejected"
tw env TYPE=g4dn.2xlarge scripts/set-type.sh; assert_rc 1; assert_text "UNCONFIRMED"; no_aws

new_sandbox; begin "shell-looking TYPE is just rejected text, never executed"
tw env "TYPE=t3.small;touch $SB/pwned" scripts/set-type.sh; assert_rc 1; assert_no_file "$SB/pwned"; no_aws
tw make set-type "TYPE=t3.small;touch $SB/pwned2"; assert_no_file "$SB/pwned2"

new_sandbox; begin "running instance: refused, and NOT stopped as a side effect"
set_state running; TW_INPUT=$'yes\n'; tw env TYPE=t3.medium scripts/set-type.sh
assert_rc 1; assert_text "RUNNING"; assert_text "make stop"; assert_not_called "stop-instances"; assert_not_called "modify-instance-attribute"
assert_eq "$(cat "$SB/mock/state")" "running" "still running"

new_sandbox; begin "already that type: nothing to do"
set_type t3.medium; tw env TYPE=t3.medium scripts/set-type.sh; assert_rc 0; assert_text "Nothing to do"; assert_not_called "modify-instance-attribute"

new_sandbox; begin "type not offered in the instance's zone: needs human review"
MOCK_ENV=("MOCK_NOT_OFFERED=t3.medium"); TW_INPUT=$'yes\n'; tw env TYPE=t3.medium scripts/set-type.sh
assert_rc 1; assert_text "does not list t3.medium"; assert_not_called "modify-instance-attribute"
new_sandbox; MOCK_ENV=(MOCK_FAIL_OFFERINGS=1); TW_INPUT=$'yes\n'; tw env TYPE=t3.medium scripts/set-type.sh
assert_rc 1; assert_text "human review"; assert_not_called "modify-instance-attribute"

new_sandbox; begin "declined confirmation changes nothing"
TW_INPUT=$'no\n'; tw env TYPE=t3.medium scripts/set-type.sh; assert_rc 1; assert_text "Cancelled"; assert_not_called "modify-instance-attribute"; assert_eq "$(count_events)" "0" "nothing recorded"

new_sandbox; begin "AWS refuses the change: failure recorded, type unchanged"
MOCK_ENV=(MOCK_FAIL_MODIFY=1); TW_INPUT=$'yes\n'; tw env TYPE=t3.medium scripts/set-type.sh
assert_rc 1; assert_event outcome failed; assert_eq "$(cat "$SB/mock/type")" "t3.small" "type unchanged"

new_sandbox; begin "AWS says OK but the type did not change: caught by verification"
MOCK_ENV=(MOCK_MODIFY_NOOP=1); TW_INPUT=$'yes\n'; tw env TYPE=t3.medium scripts/set-type.sh
assert_rc 1; assert_text "did not report type t3.medium"; assert_event outcome failed

new_sandbox; begin "menu: lists approved types, shows UNCONFIRMED as not selectable, choice 2 = t3.medium"
TW_INPUT=$'2\nyes\n'; tw scripts/set-type.sh
assert_rc 0; assert_text "1) t3.small"; assert_text "g4dn.2xlarge  (UNCONFIRMED: not selectable)"; assert_eq "$(cat "$SB/mock/type")" "t3.medium" "chose t3.medium"
new_sandbox; TW_INPUT=$'9\n'; tw scripts/set-type.sh; assert_rc 1; assert_text "Invalid choice"; no_aws

new_sandbox; begin "GPU warning when moving t3 -> g4dn"
TW_INPUT=$'no\n'; tw env TYPE=g4dn.xlarge scripts/set-type.sh; assert_text "NVIDIA driver"; assert_text "CANNOT check"
new_sandbox; set_type g4dn.xlarge; TW_INPUT=$'no\n'; tw env TYPE=t3.small scripts/set-type.sh; assert_text "removes the GPU"

new_sandbox; begin "no approved types at all: setup problem (exit 2)"
printf 't3.small UNCONFIRMED\n' > "$SB/types.txt"; tw scripts/set-type.sh; assert_rc 2; assert_text "No type is marked 'approved'"; no_aws

finish_tests
