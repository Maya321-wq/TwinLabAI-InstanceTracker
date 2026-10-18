#!/usr/bin/env bash
# help, validate, config parsing (fail-closed), allowlist parsing.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "[help]"
new_sandbox; begin "make help lists the commands and marks what changes AWS"
tw make help; assert_rc 0; assert_text "CHANGES AWS"; assert_text "make set-type TYPE=<type>"; assert_text "READ-ONLY"

echo "[validate with a good setup]"
new_sandbox; begin "make validate passes"
tw scripts/validate.sh; assert_rc 0; assert_text "All checks passed"; assert_text "instance found: state=stopped type=t3.small"
assert_text "everyone shares one key"
assert_not_called "start-instances"; assert_never_destructive

begin "validate warns when no type is approved yet"
printf 't3.small UNCONFIRMED\n' > "$SB/types.txt"; tw scripts/validate.sh
assert_rc 0; assert_text "no approved types yet"

echo "[validate failures]"
new_sandbox; begin "AWS credentials rejected"
MOCK_ENV=(MOCK_FAIL_STS=1); tw scripts/validate.sh
assert_rc 1; assert_text "AWS credentials did not work"

new_sandbox; begin "describe-instances denied: error text never leaks the key id"
MOCK_ENV=(MOCK_FAIL_DESCRIBE=1); tw scripts/validate.sh
assert_rc 1; assert_text "cannot read i-0123456789abcdef0"; assert_no_text "AKIAABCDEFGHIJKLMNOP"; assert_text "REDACTED"

new_sandbox; begin "not inside a work tree / no remote / wrong branch (git mode)"
MOCK_ENV=(MOCK_GIT_NOT_REPO=1); tw scripts/validate.sh; assert_rc 1; assert_text "not inside a Git work tree"
MOCK_ENV=(MOCK_GIT_NO_REMOTE=1); tw scripts/validate.sh; assert_rc 1; assert_text "is not configured"
MOCK_ENV=(MOCK_GIT_BRANCH=feature-x); tw scripts/validate.sh; assert_rc 1; assert_text "on branch 'feature-x'"

echo "[config parsing fails closed]"
bad_config() {  # <description> <config content> <expected message>
  new_sandbox; begin "$1"; printf '%b' "$2" > "$TW_CFG"
  tw scripts/validate.sh; assert_rc 1; assert_text "$3"; assert_not_called "ec2"
}
bad_config "missing instance id"       'REGION=us-west-2\n'                                       "INSTANCE_ID is missing"
bad_config "placeholder instance id"   'INSTANCE_ID=i-REPLACE_ME\nREGION=us-west-2\n'             "not a valid EC2 instance id"
bad_config "bad region"                'INSTANCE_ID=i-0123456789abcdef0\nREGION=west\n'            "REGION is missing or invalid"
bad_config "duplicate key (ambiguous)" 'INSTANCE_ID=i-0123456789abcdef0\nINSTANCE_ID=i-0123456789abcdef1\nREGION=us-west-2\n' "set twice"
bad_config "unknown setting"           'INSTANCE_ID=i-0123456789abcdef0\nREGION=us-west-2\nFOO=1\n' "unknown setting 'FOO'"
bad_config "not KEY=VALUE"             'INSTANCE_ID=i-0123456789abcdef0\nREGION=us-west-2\nhello world\n' "expected KEY=VALUE"
bad_config "bad coordination"          'INSTANCE_ID=i-0123456789abcdef0\nREGION=us-west-2\nCOORDINATION=maybe\n' "COORDINATION must be"
bad_config "bad operator"              'INSTANCE_ID=i-0123456789abcdef0\nREGION=us-west-2\nOPERATOR=a b;c\n' "OPERATOR must be"

new_sandbox; begin "missing config file"
rm -f "$TW_CFG"; tw scripts/validate.sh; assert_rc 1; assert_text "Config file not found"
tw scripts/status.sh status; assert_rc 2; assert_text "Config file not found"

new_sandbox; begin "a config value that looks like shell code is NOT executed"
printf 'INSTANCE_ID=$(touch %s/pwned)\nREGION=us-west-2\n' "$SB" > "$TW_CFG"
tw scripts/validate.sh; assert_rc 1; assert_no_file "$SB/pwned"
printf 'INSTANCE_ID=i-0123456789abcdef0\nREGION=us-west-2\nOPERATOR=alice\n$(touch %s/pwned2)\n' "$SB" > "$TW_CFG"
tw scripts/validate.sh; assert_rc 1; assert_no_file "$SB/pwned2"

new_sandbox; begin "Windows line endings (CRLF) are accepted"
sed -i 's/$/\r/' "$TW_CFG"; tw scripts/validate.sh; assert_rc 0

new_sandbox; begin "start/stop/set-type refuse without OPERATOR"
grep -v '^OPERATOR=' "$TW_CFG" > "$TW_CFG.n"; mv "$TW_CFG.n" "$TW_CFG"
tw scripts/start.sh; assert_rc 2; assert_text "OPERATOR is not set"
tw scripts/stop.sh;  assert_rc 2; assert_text "OPERATOR is not set"
tw env TYPE=t3.medium scripts/set-type.sh; assert_rc 2; assert_text "OPERATOR is not set"
assert_eq "$(wc -l <"$SB/mock.log" | tr -d ' ')" "0" "no AWS call was made"

begin "through make, a failing script is reported as make exit 2 with the script code shown"
new_sandbox; MOCK_ENV=(MOCK_FAIL_STS=1); tw make validate; assert_rc 2; assert_text "Error 1"

echo "[allowlist]"
new_sandbox; begin "non t3/g4dn type in the allowlist is rejected"
printf 'g5.xlarge approved\n' > "$SB/types.txt"; tw scripts/validate.sh; assert_rc 1; assert_text "not a t3/g4dn instance type"
begin "bad status word in the allowlist"
printf 't3.small yes\n' > "$SB/types.txt"; tw scripts/validate.sh; assert_rc 1; assert_text "status must be"
begin "the shipped config/instance-types.txt approves nothing by itself"
new_sandbox; rm "$SB/types.txt"; tw env TWINLAB_TYPES_FILE="$SB/repo/config/instance-types.txt" make validate
assert_text "0 approved, 6 UNCONFIRMED"; assert_no_text "g5.xlarge approved"
assert_eq "$(grep -c 'g5' "$REPO_ROOT/config/instance-types.txt" | tr -d ' ')" "1" "g5 appears only in the explanatory comment"
assert_eq "$(grep -E '^g5' "$REPO_ROOT/config/instance-types.txt" | wc -l | tr -d ' ')" "0" "no g5 entry"

finish_tests
