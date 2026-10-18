#!/usr/bin/env bash
# Two "laptops" (two clones) coordinating through a REAL git, but the only remote is a bare repo in a
# temp directory. There is no network and no real remote anywhere: the test asserts that below.
# The AWS CLI is still the fake one. This test needs `git` installed to run.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v git >/dev/null 2>&1 || { echo "git is not installed: skipping (the fake-git tests still cover the logic)"; exit 0; }

G() { env -i HOME="$SB/home" PATH="$SB/safebin" GIT_CONFIG_GLOBAL="$SB/gitconfig" GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 git "$@"; }

setup_two_laptops() {
  new_sandbox real-git
  G init -q --bare "$SB/remote.git"
  ( cd "$SB/repo" && G init -q -b main . && G add -A && G commit -q -m seed && G remote add origin "$SB/remote.git" && G push -q -u origin main )
  G clone -q "$SB/remote.git" "$SB/repoB"
  write_config "$SB/cfgA" alice; write_config "$SB/cfgB" bob
  cat > "$SB/driver.sh" <<'EOF'
#!/usr/bin/env bash
# Drives ONLY the claim/record helpers (no AWS): bash driver.sh <repo-dir> <acquire|full>
set -u
source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/ledger.sh"
need_config; require_operator
ACTION=start; OP_ID="$(new_op_id)"; HOST=testhost; CALLER_ARN=unknown
ledger_acquire start observed_state=stopped instance_type=t3.small aws_caller_arn=unknown || exit 1
echo ACQUIRED
if [[ "${2:-acquire}" == full ]]; then
  ledger_finish outcome=success observed_state=running instance_type=t3.small || exit 3
  echo DONE
fi
EOF
}
laptop() {  # <A|B> <acquire|full>
  if [[ "$1" == A ]]; then TW_DIR="$SB/repo";  TW_CFG="$SB/cfgA"; else TW_DIR="$SB/repoB"; TW_CFG="$SB/cfgB"; fi
  tw bash "$SB/driver.sh" "$TW_DIR" "${2:-acquire}"
}
remote_has_claim() { G -C "$SB/remote.git" cat-file -e main:ledger/claim.json 2>/dev/null; }
remote_commits()   { G -C "$SB/remote.git" rev-list --count main; }

echo "[the sandbox cannot reach any real remote]"
setup_two_laptops
begin "both clones point at the local bare repo inside the temp dir"
assert_eq "$(G -C "$SB/repo" remote get-url origin)"  "$SB/remote.git" "laptop A remote is local"
assert_eq "$(G -C "$SB/repoB" remote get-url origin)" "$SB/remote.git" "laptop B remote is local"
assert_eq "$(env -i PATH="$SB/safebin" "$SB/safebin/bash" -c 'command -v aws' 2>&1)" "" "real aws not on PATH"

echo "[sequential: A claims, B is refused]"
begin "A's claim is pushed; B then pulls it and is refused without pushing anything"
laptop A; assert_rc 0; assert_text "ACQUIRED"; remote_has_claim && _ok "claim is on the remote" || _bad "claim not on the remote"
n="$(remote_commits)"
laptop B; assert_rc 1; assert_text "Another operation is in progress"; assert_text "alice"; assert_eq "$(remote_commits)" "$n" "B pushed nothing"
assert_eq "$(G -C "$SB/repoB" status --porcelain)" "" "B's work tree is clean"

begin "A's own unfinished claim also blocks A from starting a second operation"
laptop A full; assert_rc 1; assert_text "Another operation is in progress"

echo "[the race: both pass the pre-check, A pushes first]"
setup_two_laptops
begin "B's claim push is rejected, B rolls back completely, AWS would never be called"
cat > "$SB/repoB/.git/hooks/pre-push" <<EOF
#!/usr/bin/env bash
# Simulates alice winning the race while bob's push is in flight.
env -i HOME="$SB/home" PATH="$SB/mockbin:$SB/safebin" LANG=C.UTF-8 GIT_CONFIG_GLOBAL="$SB/gitconfig" GIT_CONFIG_SYSTEM=/dev/null \\
    TWINLAB_CONFIG="$SB/cfgA" TWINLAB_TYPES_FILE="$SB/types.txt" TWINLAB_TEST_SANDBOX=1 MOCK_DIR="$SB/mock" MOCK_LOG="$SB/mock.log" TMPDIR="$SB/tmp" \\
    bash "$SB/driver.sh" "$SB/repo" acquire > "$SB/hook-out.txt" 2>&1
exit 0
EOF
chmod +x "$SB/repoB/.git/hooks/pre-push"
head_before="$(G -C "$SB/repoB" rev-parse HEAD)"
laptop B
assert_rc 1; assert_text "Could not publish the claim"; assert_text "Nothing was changed in AWS"
grep -q ACQUIRED "$SB/hook-out.txt" && _ok "alice really did claim first (hook output)" || _bad "hook did not run" "$(cat "$SB/hook-out.txt")"
remote_has_claim && _ok "the claim on the remote is alice's" || _bad "no claim on remote"
G -C "$SB/remote.git" show main:ledger/claim.json | grep -q '"operator_declared": "alice"' && _ok "remote claim belongs to alice" || _bad "remote claim is not alice's"
assert_eq "$(G -C "$SB/repoB" rev-parse HEAD)" "$head_before" "B's HEAD is back where it started (own commit undone)"
assert_eq "$(G -C "$SB/repoB" status --porcelain)" "" "B has no leftover claim/event files"
assert_no_file "$SB/repoB/ledger/claim.json"
assert_eq "$(count_events "$SB/repoB")" "0" "B has no events"
assert_not_called "start-instances"

begin "B retries: now fast-forwards, sees alice's claim, and is refused"
laptop B; assert_rc 1; assert_text "Another operation is in progress"; assert_text "alice"

echo "[other real-git situations]"
setup_two_laptops; begin "full cycle on one laptop leaves no claim on the remote and two events"
laptop A full; assert_rc 0; assert_text "DONE"
remote_has_claim && _bad "claim still on remote" || _ok "claim removed on the remote"
assert_eq "$(G -C "$SB/remote.git" ls-tree -r --name-only main | grep -c 'ledger/events/.*\.json')" "2" "intent + result events on the remote"
laptop B full; assert_rc 0; assert_text "DONE"; _ok "B can claim after A finished (B syncs automatically)"

setup_two_laptops; begin "unreachable remote (fetch fails): refused before anything is written"
G -C "$SB/repoB" remote set-url origin "$SB/does-not-exist.git"
laptop B; assert_rc 1; assert_text "git fetch failed"; assert_eq "$(count_events "$SB/repoB")" "0" "no events"

setup_two_laptops; begin "uncommitted file in ledger/ is refused"
mkdir -p "$SB/repoB/ledger/events"; echo '{}' > "$SB/repoB/ledger/events/stray.json"
laptop B; assert_rc 1; assert_text "uncommitted changes"

setup_two_laptops; begin "wrong branch is refused"
G -C "$SB/repoB" switch -q -c feature; laptop B; assert_rc 1; assert_text "git switch main"

setup_two_laptops; begin "unrelated uncommitted work elsewhere is preserved, not stashed or reset"
echo "my notes" > "$SB/repoB/NOTES.txt"; echo "# edit" >> "$SB/repoB/README-local.md"
laptop B full; assert_rc 0
assert_eq "$(cat "$SB/repoB/NOTES.txt")" "my notes" "untracked file untouched"
assert_eq "$(G -C "$SB/repoB" status --porcelain | sort | tr '\n' ' ')" "?? NOTES.txt ?? README-local.md " "only my own files remain uncommitted"

finish_tests
