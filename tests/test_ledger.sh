#!/usr/bin/env bash
# Records: derived sessions with CONTROLLED data, malformed/incomplete records, recover, clear-claim.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

put_event() {  # <ts> <op> <action> <kind> <outcome> <operator> [type]   -> writes ledger/events/<ts>-<op>-...json
  python3 - "$TW_DIR/ledger/events" "$@" <<'PY'
import json, sys
d, ts, op, action, kind, outcome, who = sys.argv[1:8]
typ = sys.argv[8] if len(sys.argv) > 8 else "t3.small"
ev = {"schema": 1, "ts_utc": ts, "op_id": op, "action": action, "kind": kind, "operator_declared": who,
      "operator_verified": False, "host": "h", "instance_type": typ}
if outcome != "-": ev["outcome"] = outcome
name = "%s-%s-%s-%s.json" % (ts.replace(":", "").replace("-", ""), op, action, kind)
json.dump(ev, open(d + "/" + name, "w"))
PY
}
write_claim() {  # <minutes until expiry> [operator]
  python3 - "$TW_DIR/ledger/claim.json" "$1" "${2:-bob}" <<'PY'
import json, sys, datetime as dt
p, off, who = sys.argv[1], int(sys.argv[2]), sys.argv[3]
now = dt.datetime.now(dt.timezone.utc); f = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"schema": 1, "op_id": "op-test-1", "action": "stop", "operator_declared": who, "host": "bobs-laptop",
           "created_utc": f(now - dt.timedelta(minutes=30)), "expires_utc": f(now + dt.timedelta(minutes=off))}, open(p, "w"))
PY
}
tree_hash() { (cd "$TW_DIR/ledger" && find . -type f | sort | xargs -r cat | cksum); }

echo "[history from controlled data]"
new_sandbox; begin "paired start/stop gives the exact observed duration; open session is flagged"
put_event 2026-10-01T08:00:00Z op-a start result success alice t3.small
put_event 2026-10-01T10:30:00Z op-b stop  result success bob   t3.small
put_event 2026-10-02T09:00:00Z op-c start result success carol g4dn.xlarge
tw scripts/history.sh; assert_rc 0
assert_text "2026-10-01T08:00:00Z -> 2026-10-01T10:30:00Z  2h 30m"; assert_text "start:alice stop:bob"
assert_text "start:carol stop:- still open: no stop recorded yet"; assert_text "not an AWS bill"; assert_text "SELF-DECLARED"

new_sandbox; begin "stop without a start, and two starts in a row: shown as gaps, nothing invented"
put_event 2026-10-01T10:00:00Z op-a stop  result success bob
put_event 2026-10-01T11:00:00Z op-b start result success alice
put_event 2026-10-01T12:00:00Z op-c start result success alice
tw scripts/history.sh
assert_text "no tracked start (started outside these tools or record missing)"; assert_text "no stop recorded before the next start"

new_sandbox; begin "failed/timeout operations and interrupted operations need attention"
put_event 2026-10-01T08:00:00Z op-a start result failed alice
put_event 2026-10-01T09:00:00Z op-b stop  result timeout bob
put_event 2026-10-01T10:00:00Z op-c start intent -  carol
tw scripts/history.sh; assert_text "Needs attention"; assert_text "start failed by alice"; assert_text "stop timeout by bob"
assert_text "op-c"; assert_text "no result recorded (interrupted?)"

echo "[malformed or incomplete records]"
new_sandbox; begin "garbage and missing-timestamp files are reported, never fabricated, never crash history"
put_event 2026-10-01T08:00:00Z op-a start result success alice
echo '{broken' > "$TW_DIR/ledger/events/zzz-garbage.json"
echo '{"op_id":"op-x","action":"start","kind":"result","outcome":"success"}' > "$TW_DIR/ledger/events/zzz-no-timestamp.json"
tw scripts/history.sh; assert_rc 0; assert_text "events=1 unreadable=2"; assert_text "unreadable event file: zzz-garbage.json"; assert_text "unreadable event file: zzz-no-timestamp.json"
assert_text "still open"

new_sandbox; begin "history works with no ledger at all"
rm -rf "$TW_DIR/ledger"; tw scripts/history.sh; assert_rc 0; assert_text "(none recorded)"

new_sandbox; begin "legacy runtime-history.csv is still shown; legacy active-session.env is NEVER executed"
mkdir -p "$TW_DIR/runtime"
printf 'instance_id,start_utc,stop_utc,instance_type,runtime_seconds\ni-1,2026-09-01T08:00:00Z,2026-09-01T09:00:00Z,t3.small,3600\n' > "$TW_DIR/runtime/runtime-history.csv"
printf 'INSTANCE_ID=i-1\n$(touch %s/pwned3)\n`touch %s/pwned4`\nSTART_UTC=2026-09-01T08:00:00Z\n' "$SB" "$SB" > "$TW_DIR/runtime/active-session.env"
tw scripts/history.sh; assert_text "Legacy records"; assert_text "3600"
tw scripts/recover.sh; assert_text "Legacy file runtime/active-session.env"; assert_text "NOT used any more"
assert_no_file "$SB/pwned3"; assert_no_file "$SB/pwned4"

echo "[secrets never reach the ledger]"
new_sandbox; begin "key-like text is scrubbed from events"
tw python3 -I tools/ledger.py --dir ledger event-add --op-id op-s --action start --kind result --operator alice --host h \
   outcome=failed "error=denied AKIAABCDEFGHIJKLMNOP secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
assert_rc 0; grep -rqE 'AKIA|wJalr' "$TW_DIR/ledger" && _bad "secret text stored in ledger" || _ok "secret text not stored"
tw python3 -I tools/ledger.py --dir ledger event-add --op-id op-s --action start --kind result --operator alice --host h outcome=failed password=hunter2
assert_rc 1; assert_text "unknown field"

begin "two events with the same name never overwrite each other"
for i in 1 2; do tw python3 -I tools/ledger.py --dir ledger event-add --op-id op-same --action stop --kind result --operator alice --host h outcome=success; done
assert_eq "$(count_events)" "3" "both new events kept (plus the earlier one)"

echo "[recover is read-only]"
new_sandbox; begin "records say stopped, AWS says running: mismatch reported, nothing changed"
put_event 2026-10-01T10:00:00Z op-a stop result success bob; set_state running
before="$(tree_hash)"; tw scripts/recover.sh
assert_rc 0; assert_text "Mismatch: records say 'stopped' but AWS says 'running'"; assert_eq "$(tree_hash)" "$before" "ledger unchanged"
assert_not_called "start-instances"; assert_not_called "stop-instances"; assert_not_called "modify-instance-attribute"; assert_not_called "git push"; assert_not_called "git commit"

new_sandbox; begin "running with no records at all: explains an untracked start"
set_state running; tw scripts/recover.sh; assert_text "no tracked start exists"; assert_text "make sync"

new_sandbox; begin "interrupted operation is named; AWS unreadable is handled"
put_event 2026-10-01T10:00:00Z op-z start intent - dave
MOCK_ENV=(MOCK_FAIL_DESCRIBE=1); tw scripts/recover.sh
assert_rc 0; assert_text "Interrupted:"; assert_text "AWS could not be read"; assert_text "make validate"; assert_no_text "AKIAABCDEFGHIJKLMNOP"

new_sandbox; begin "stale claim: diagnosed with the exact next command"
write_claim -10 bob; tw scripts/recover.sh; assert_text "STALE"; assert_text "make clear-claim"

echo "[clear-claim]"
new_sandbox; begin "no claim: nothing to do"
TW_INPUT=$'clear\n'; tw scripts/clear-claim.sh; assert_rc 0; assert_text "no claim"

new_sandbox; begin "ACTIVE claim is never cleared"
write_claim 30 bob; TW_INPUT=$'clear\n'; tw scripts/clear-claim.sh
assert_rc 1; assert_text "still active"; assert_file "$TW_DIR/ledger/claim.json"; assert_not_called "git push"

new_sandbox; begin "stale claim: declined leaves it; confirmed clears it, records it, pushes it; AWS untouched"
write_claim -10 bob; TW_INPUT=$'no\n'; tw scripts/clear-claim.sh
assert_rc 1; assert_text "Cancelled"; assert_file "$TW_DIR/ledger/claim.json"; assert_not_called "git push"
TW_INPUT=$'clear\n'; tw scripts/clear-claim.sh
assert_rc 0; assert_text "cleared stale claim op-test-1"; assert_no_file "$TW_DIR/ledger/claim.json"
grep -rqF '"kind": "claim_cleared"' "$TW_DIR/ledger/events" && _ok "claim_cleared event written" || _bad "no claim_cleared event"
assert_called "git push"; assert_not_called "start-instances"; assert_not_called "stop-instances"; assert_never_destructive

new_sandbox; begin "unreadable claim.json can be cleared; failed push is reported with exit 3"
mkdir -p "$TW_DIR/ledger"; echo '{oops' > "$TW_DIR/ledger/claim.json"
MOCK_ENV=(MOCK_GIT_PUSH_FAIL=1); TW_INPUT=$'clear\n'; tw scripts/clear-claim.sh
assert_rc 3; assert_text "NOT pushed"; assert_text "make recover"

finish_tests
