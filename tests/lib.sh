#!/usr/bin/env bash
# Test harness. Source it from a test file.
#
# SAFETY DESIGN: every command under test runs through tw(), which uses `env -i` and a PATH made of
#   1. mockbin/  - the fake aws (and fake git), which refuse to run outside this sandbox
#   2. safebin/  - symlinks to a short list of ordinary tools; it contains NO aws and (unless a test
#                  asks for a local-only real git) NO git
# so the real AWS CLI cannot be found and a real remote cannot be pushed to. HOME and every
# AWS_*/GIT_* setting point inside a temp directory. The repo under test is COPIED into the sandbox,
# so ledger/ and local/ files never land in your real working tree.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SAFE_TOOLS="bash env make python3 date sleep mktemp mkdir cat grep sed awk tr cut sort head tail wc rm cp mv ls dirname basename hostname id uname touch tee readlink chmod find diff cmp true false printf test"
PASS=0; FAIL=0
TMP_ROOT="$(mktemp -d)"; trap 'rm -rf "$TMP_ROOT"' EXIT
MOCK_ENV=(); TW_INPUT=""; TW_DIR=""; TW_CFG=""; RC=0; SB=""

# new_sandbox [real-git]
new_sandbox() {
  SB="$(mktemp -d "$TMP_ROOT/sb.XXXXXX")"
  mkdir -p "$SB"/{mockbin,safebin,home/.aws,mock,repo,tmp}
  local t p
  for t in $SAFE_TOOLS; do
    p="$(command -v "$t" 2>/dev/null)"; [[ "$p" == /* ]] && ln -s "$p" "$SB/safebin/$t"
  done
  cp "$TESTS_DIR/mocks/bin/aws" "$SB/mockbin/aws"; chmod +x "$SB/mockbin/aws"
  if [[ "${1:-fake}" == real-git ]]; then
    ln -s "$(command -v git)" "$SB/safebin/git"
  else
    cp "$TESTS_DIR/mocks/bin/git" "$SB/mockbin/git"; chmod +x "$SB/mockbin/git"
  fi
  cp -r "$REPO_ROOT/Makefile" "$REPO_ROOT/scripts" "$REPO_ROOT/tools" "$REPO_ROOT/config" "$SB/repo/"
  mkdir -p "$SB/repo/ledger/events" "$SB/repo/tests"
  printf '#!/usr/bin/env bash\necho "tests/run.sh would run here"\n' > "$SB/repo/tests/run.sh"; chmod +x "$SB/repo/tests/run.sh"
  echo stopped > "$SB/mock/state"; echo t3.small > "$SB/mock/type"; : > "$SB/mock.log"
  write_config "$SB/twinlab.env" alice
  printf 't3.small\nt3.medium\nt3.large\nt3.xlarge\ng4dn.xlarge\ng4dn.2xlarge\ng5.xlarge APPROVAL_REQUIRED\n' > "$SB/types.txt"
  printf '[user]\n\tname = Test\n\temail = test@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$SB/gitconfig"
  MOCK_ENV=(); TW_INPUT=""; TW_DIR="$SB/repo"; TW_CFG="$SB/twinlab.env"
}

write_config() {  # <path> <operator>
  cat > "$1" <<EOF
INSTANCE_ID=i-0123456789abcdef0
REGION=us-west-2
OPERATOR=$2
COORDINATION=git
GIT_REMOTE=origin
GIT_BRANCH=main
CLAIM_TTL_MINUTES=60
WAIT_TIMEOUT_SECONDS=2
POLL_SECONDS=1
EOF
}
cfg_set() {  # cfg_set KEY VALUE  (edits $TW_CFG)
  grep -v "^$1=" "$TW_CFG" > "$TW_CFG.new"; echo "$1=$2" >> "$TW_CFG.new"; mv "$TW_CFG.new" "$TW_CFG"
}
set_state() { echo "$1" > "$SB/mock/state"; rm -f "$SB/mock/target"; }
set_type()  { echo "$1" > "$SB/mock/type"; }

# tw <command...> : runs inside the sandbox. Sets RC; output in $SB/out.txt and $SB/err.txt
tw() {
  ( cd "$TW_DIR" && printf '%s' "$TW_INPUT" | env -i HOME="$SB/home" PATH="$SB/mockbin:$SB/safebin" LANG=C.UTF-8 \
      AWS_CONFIG_FILE="$SB/home/.aws/config" AWS_SHARED_CREDENTIALS_FILE="$SB/home/.aws/credentials" \
      GIT_CONFIG_GLOBAL="$SB/gitconfig" GIT_CONFIG_SYSTEM=/dev/null TMPDIR="$SB/tmp" \
      TWINLAB_CONFIG="$TW_CFG" TWINLAB_TYPES_FILE="$SB/types.txt" \
      TWINLAB_TEST_SANDBOX=1 MOCK_DIR="$SB/mock" MOCK_LOG="$SB/mock.log" \
      ${MOCK_ENV[@]+"${MOCK_ENV[@]}"} "$@" ) >"$SB/out${TW_TAG:-}.txt" 2>"$SB/err${TW_TAG:-}.txt"
  RC=$?
}
all_text() { cat "$SB/out.txt" "$SB/err.txt"; }
mocklog()  { cat "$SB/mock.log"; }
events_dir() { echo "${1:-$TW_DIR}/ledger/events"; }
count_events() { find "$(events_dir "${1:-}")" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }

# ------------------------------------------------------------- assertions
_ok()  { PASS=$((PASS+1)); printf '    PASS  %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '    FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '          %s\n' "$2"; }
begin() { printf '  - %s\n' "$1"; }
assert_rc()   { [[ "$RC" == "$1" ]] && _ok "exit code $1" || _bad "expected exit code $1, got $RC" "$(all_text | tail -n 4 | tr '\n' '|')"; }
assert_text() { all_text | grep -qF -- "$1" && _ok "output contains: $1" || _bad "output missing: $1" "$(all_text | tail -n 4 | tr '\n' '|')"; }
assert_no_text() { all_text | grep -qF -- "$1" && _bad "output must NOT contain: $1" || _ok "output does not contain: $1"; }
assert_called()     { mocklog | grep -qF -- "$1" && _ok "called: $1" || _bad "expected call missing: $1"; }
assert_not_called() { mocklog | grep -qF -- "$1" && _bad "must NOT have been called: $1" || _ok "not called: $1"; }
assert_eq()   { [[ "$1" == "$2" ]] && _ok "$3" || _bad "$3" "expected '$2' got '$1'"; }
assert_file()    { [[ -e "$1" ]] && _ok "exists: ${1#$SB/}" || _bad "missing file: ${1#$SB/}"; }
assert_no_file() { [[ ! -e "$1" ]] && _ok "absent: ${1#$SB/}" || _bad "unexpected file: ${1#$SB/}"; }
# Every test also proves nothing dangerous was attempted.
assert_never_destructive() {
  mocklog | grep -qE 'terminate-instances|delete-volume|delete-snapshot|release-address|deregister' \
    && _bad "a destructive AWS call was made" || _ok "no terminate/delete call made"
}
finish_tests() {
  echo; printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
}
