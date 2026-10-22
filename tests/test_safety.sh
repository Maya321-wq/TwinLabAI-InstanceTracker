#!/usr/bin/env bash
# Proves the test setup cannot reach real AWS/Git, and that `make -n` (dry run) executes nothing.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

echo "[sandbox isolation]"
begin "real aws and git are not on the sandbox PATH"
out="$(env -i PATH="$SB/safebin" "$SB/safebin/bash" -c 'command -v aws; command -v git' 2>&1)"; rc=$?
assert_eq "$out" "" "aws and git cannot be found without the mocks"
assert_eq "$rc" "1" "lookup failed as expected"

begin "inside tw(), 'aws' and 'git' resolve to the mocks"
tw bash -c 'command -v aws; command -v git'
assert_eq "$(cat "$SB/out.txt")" "$SB/mockbin/aws
$SB/mockbin/git" "both resolve to mockbin"

begin "the mocks refuse to run outside the sandbox"
env -i PATH=/usr/bin:/bin "$SB/mockbin/aws" ec2 start-instances >/dev/null 2>&1; assert_eq "$?" "99" "mock aws exits 99 without sandbox vars"
env -i PATH=/usr/bin:/bin "$SB/mockbin/git" push >/dev/null 2>&1; assert_eq "$?" "99" "mock git exits 99 without sandbox vars"

begin "HOME and AWS config files point into the sandbox"
tw bash -c 'echo "$HOME|$AWS_CONFIG_FILE|$AWS_SHARED_CREDENTIALS_FILE"'
assert_eq "$(cat "$SB/out.txt")" "$SB/home|$SB/home/.aws/config|$SB/home/.aws/credentials" "all inside sandbox"

begin "make configure refuses the default profile and never uses 'aws configure set'"
tw make configure PROFILE=default
assert_rc 2; assert_text "Refusing to write the 'default' profile"; assert_eq "$(wc -l <"$SB/mock.log" | tr -d ' ')" "0" "no AWS call at all"
: > "$SB/mock.log"; tw make configure PROFILE=twinlab
assert_called "aws configure --profile twinlab"; assert_not_called "aws configure set"; assert_not_called "--profile default"

echo "[dry run: make -n must only PRINT]"
for target in start stop set-type history recover clear-claim configure sync notify-test reminder-test status validate type uptime dcv test help; do
  new_sandbox; MOCK_ENV=(); TW_INPUT=$'yes\nSTOP\nclear\n1\n'; set_state running
  begin "make -n $target runs nothing"
  tw make -n "$target" TYPE=t3.medium
  assert_rc 0
  assert_eq "$(wc -l <"$SB/mock.log" | tr -d ' ')" "0" "no aws/git call logged"
  assert_eq "$(count_events)" "0" "no ledger event written"
  assert_no_file "$SB/repo/ledger/claim.json"
  assert_no_file "$SB/repo/local"
done
begin "make -n prints the script line (so you can see what would run)"
new_sandbox; tw make -n start; assert_text "scripts/start.sh"

echo "[control: the same check DOES catch the old Makefile]"
if [[ -f "$REPO_ROOT/Makefile.v2.backup" ]]; then
  for target in start set-type; do
    new_sandbox; cp "$REPO_ROOT/Makefile.v2.backup" "$SB/repo/Makefile"; mkdir -p "$SB/repo/runtime"
    begin "OLD Makefile: make -n $target wrongly runs mutating commands (proves this test can fail)"
    TW_INPUT=$'1\n'; tw make -n "$target"
    mocklog | grep -qE 'start-instances|modify-instance-attribute' && _ok "old Makefile executed a mutating AWS call under -n" || _bad "control did not reproduce the hazard" "$(mocklog | tr '\n' '|')"
  done
else
  echo "  (Makefile.v2.backup not present: control skipped)"
fi

echo "[static checks of the Makefile and scripts]"
begin "Makefile has no recursive make, \$(shell), \$(call), \$(eval) or +/- recipe prefixes"
bad="$(grep -v '^[[:space:]]*#' "$REPO_ROOT/Makefile" | grep -nE '\$\((MAKE|shell|call|eval)\b|\$\{MAKE\}' || true)"
assert_eq "$bad" "" "no recursive/shell expansion"
bad="$(grep -v '^[[:space:]]*#' "$REPO_ROOT/Makefile" | grep -E '; *[@+-]' | grep -v '^help:' | grep -vE '; @bash (scripts|tests)/[a-z.-]+\.sh( [a-z]+)?$' || true)"
assert_eq "$bad" "" "every recipe is a single call to scripts/ or tests/"

begin "scripts never source data files and never use eval/force/destructive commands"
bad="$(grep -rhE '^[[:space:]]*(source|\.)[[:space:]]' "$REPO_ROOT/scripts" | grep -vE 'lib/(common|ledger|notify)\.sh"' || true)"
assert_eq "$bad" "" "only lib/*.sh are sourced"
bad="$(grep -rnwE 'eval' "$REPO_ROOT/scripts" "$REPO_ROOT/tools" || true)"; assert_eq "$bad" "" "no eval"
bad="$(grep -rnE 'terminate-instances|delete-volume|delete-snapshot|release-address|reset --hard|clean -[a-z]*f|push (-f|--force)|rm -rf|aws configure set' "$REPO_ROOT/scripts" "$REPO_ROOT/tools" "$REPO_ROOT/Makefile" || true)"
assert_eq "$bad" "" "no terminate/delete/force/hard-reset/dry-run flag anywhere"

finish_tests
