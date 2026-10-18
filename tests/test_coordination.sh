#!/usr/bin/env bash
# Claims, Git failures, and "AWS succeeded but the record could not be saved".
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

count_log(){ grep -cF -- "$1" "$SB/mock.log" | tr -d ' '; }
has_event(){ grep -rlF "\"$1\": \"$2\"" "$TW_DIR/ledger/events" >/dev/null 2>&1; }
assert_event() { has_event "$1" "$2" && _ok "event has $1=$2" || _bad "no event with $1=$2"; }
write_claim() {  # <minutes until expiry (negative = already expired)> [operator]  -> $TW_DIR/ledger/claim.json
  mkdir -p "$TW_DIR/ledger"
  python3 - "$TW_DIR/ledger/claim.json" "$1" "${2:-bob}" <<'PY'
import json, sys, datetime as dt
p, off, who = sys.argv[1], int(sys.argv[2]), sys.argv[3]
now = dt.datetime.now(dt.timezone.utc); f = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"schema": 1, "op_id": "op-test-1", "action": "stop", "operator_declared": who, "host": "bobs-laptop",
           "created_utc": f(now - dt.timedelta(minutes=30)), "expires_utc": f(now + dt.timedelta(minutes=off))}, open(p, "w"))
PY
}
refuses_cleanly() { assert_rc 1; assert_not_called "start-instances"; assert_not_called "stop-instances"; assert_not_called "modify-instance-attribute"; }

echo "[someone else's claim]"
new_sandbox; begin "ACTIVE claim by bob blocks start, stop and set-type; the claim is left alone"
write_claim 30 bob
TW_INPUT=$'yes\n'; tw scripts/start.sh; refuses_cleanly; assert_text "Another operation is in progress"; assert_text "bob"
set_state running; TW_INPUT=$'STOP\n'; tw scripts/stop.sh; refuses_cleanly; assert_text "Another operation is in progress"
set_state stopped; TW_INPUT=$'yes\n'; tw env TYPE=t3.medium scripts/set-type.sh; refuses_cleanly
grep -q '"operator_declared": "bob"' "$TW_DIR/ledger/claim.json" && _ok "bob's claim untouched" || _bad "bob's claim was modified"
assert_eq "$(count_events)" "0" "no events written"

new_sandbox; begin "STALE claim blocks everything and points to make recover"
write_claim -10 bob; TW_INPUT=$'yes\n'; tw scripts/start.sh; refuses_cleanly; assert_text "stale claim"; assert_text "make recover"

new_sandbox; begin "MALFORMED claim blocks everything and points to make recover"
mkdir -p "$TW_DIR/ledger"; echo '{not json' > "$TW_DIR/ledger/claim.json"
TW_INPUT=$'yes\n'; tw scripts/start.sh; refuses_cleanly; assert_text "unreadable"; assert_text "make recover"

echo "[git problems stop the operation BEFORE AWS is touched]"
case_git() {  # <description> <expected message> <MOCK_VAR=value>...
  new_sandbox; begin "$1"; MOCK_ENV=("${@:3}"); TW_INPUT=$'yes\n'; tw scripts/start.sh
  refuses_cleanly; assert_text "$2"; assert_no_file "$TW_DIR/ledger/claim.json"; assert_eq "$(count_events)" "0" "no events left behind"
}
case_git "claim push rejected (teammate got there first)" "Nothing was changed in AWS" "MOCK_GIT_PUSH_FAIL=1"
assert_called "git reset"
case_git "claim push fails: network down" "Could not resolve host" "MOCK_GIT_PUSH_NETFAIL=1"
case_git "claim commit fails" "Could not commit the claim" "MOCK_GIT_COMMIT_FAIL=1"
case_git "uncommitted changes in ledger/" "uncommitted changes" "MOCK_GIT_DIRTY=?? ledger/events/x.json"
case_git "wrong branch" "git switch main" "MOCK_GIT_BRANCH=feature-x"
case_git "no remote configured" "is not configured" "MOCK_GIT_NO_REMOTE=1"
case_git "git fetch fails (network)" "git fetch failed" "MOCK_GIT_FETCH_FAIL=1"
case_git "unpushed local commits" "not pushed" "MOCK_GIT_AHEAD=2"
case_git "cannot fast-forward to latest records" "fast-forward" "MOCK_GIT_BEHIND=1" "MOCK_GIT_PULL_FAIL=1"
case_git "not a git work tree" "Not inside a Git work tree" "MOCK_GIT_NOT_REPO=1"

new_sandbox; begin "behind the remote: fast-forwards first (and nothing else), then proceeds"
MOCK_ENV=(MOCK_GIT_BEHIND=1); TW_INPUT=$'yes\n'; tw scripts/start.sh
assert_rc 0; assert_called "git pull --ff-only origin main"; assert_not_called "--rebase"; assert_not_called "--hard"

new_sandbox; begin "read-only commands never commit, push or pull"
MOCK_ENV=(MOCK_GIT_DIRTY="?? ledger/x"); for c in "scripts/status.sh status" "scripts/history.sh" "scripts/recover.sh"; do tw $c; assert_rc 0; done
for g in "git push" "git commit" "git pull" "git fetch" "git add"; do assert_not_called "$g"; done

echo "[AWS succeeded but the record could not be saved]"
new_sandbox; begin "result push fails: exit 3, real state reported, 'do not repeat' guidance"
MOCK_ENV=(MOCK_GIT_PUSH_FAIL_AFTER=1); TW_INPUT=$'yes\n'; tw scripts/start.sh
assert_rc 3; assert_eq "$(cat "$SB/mock/state")" "running" "AWS really is running"
assert_text "NOT fully saved"; assert_text "Do NOT repeat"; assert_text "make recover"
assert_eq "$(count_log 'start-instances')" "1" "one start request"; assert_eq "$(count_events)" "2" "events kept on disk"
begin "recover then explains the unpushed commit and the exact git command (and changes nothing)"
: > "$SB/mock.log"; MOCK_ENV=(MOCK_GIT_AHEAD=1); tw scripts/recover.sh
assert_rc 0; assert_text "1 commit(s) not pushed"; assert_text "git push origin main"; assert_not_called "start-instances"; assert_not_called "stop-instances"; assert_not_called "git push"

new_sandbox; begin "result commit fails: exit 3, record files stay on disk, recover tells you how to save them"
MOCK_ENV=(MOCK_GIT_COMMIT_FAIL_AFTER=1); TW_INPUT=$'yes\n'; tw scripts/start.sh
assert_rc 3; assert_text "NOT fully saved"; assert_eq "$(cat "$SB/mock/state")" "running" "AWS really is running"
: > "$SB/mock.log"; MOCK_ENV=(MOCK_GIT_DIRTY="?? ledger/events/x.json"); tw scripts/recover.sh
assert_text "Unsaved changes in ledger/"; assert_text "git add -A -- ledger"; assert_rc 0
begin "while records are unsaved, the next operation is refused (no AWS call)"
: > "$SB/mock.log"; MOCK_ENV=(MOCK_GIT_DIRTY="?? ledger/events/x.json"); set_state stopped; TW_INPUT=$'yes\n'; tw scripts/start.sh
refuses_cleanly; assert_text "uncommitted changes"

echo "[local mode: honest about its limits]"
new_sandbox; begin "COORDINATION=local works without any git call and says it only protects this machine"
cfg_set COORDINATION local; TW_INPUT=$'yes\n'; tw scripts/start.sh
assert_rc 0; assert_text "protect THIS computer"; assert_eq "$(grep -c '^git ' "$SB/mock.log" | tr -d ' ')" "0" "no git call"
assert_eq "$(count_events "$TW_DIR/local")" "2" "events under local/ledger"; assert_no_file "$TW_DIR/ledger/claim.json"

new_sandbox; begin "two simultaneous starts on one machine: exactly one start request, no claim left over"
cfg_set COORDINATION local; cfg_set POLL_SECONDS 1; cfg_set WAIT_TIMEOUT_SECONDS 3
( TW_TAG=A TW_INPUT=$'yes\n' tw scripts/start.sh; echo "$RC" > "$SB/rcA" ) &
( TW_TAG=B TW_INPUT=$'yes\n' tw scripts/start.sh; echo "$RC" > "$SB/rcB" ) &
wait
assert_eq "$(count_log 'start-instances')" "1" "AWS was asked to start exactly once"
assert_no_file "$TW_DIR/local/ledger/claim.json"
a="$(cat "$SB/rcA")"; b="$(cat "$SB/rcB")"
[[ ( "$a" == 0 && ( "$b" == 0 || "$b" == 1 ) ) || ( "$b" == 0 && "$a" == 1 ) ]] && _ok "outcomes were (0,0 or 0,1): never two starts (rc A=$a B=$b)" || _bad "unexpected exit codes A=$a B=$b"

finish_tests
