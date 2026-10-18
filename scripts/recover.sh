#!/usr/bin/env bash
# make recover - READ-ONLY diagnosis. It never starts, stops or changes anything:
# it compares AWS, the claim/ledger records and Git, then tells you what to do.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/ledger.sh"
need_config

info "== Recovery diagnosis (read-only: nothing is changed) =="
state=unknown
if read_instance; then state="$AWS_STATE"; print_instance_summary
else warn "AWS could not be read: $LAST_AWS_ERROR"; fi
echo
ledger diagnose --aws-state "$state"

echo
if [[ "$COORDINATION" == git ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  dirty="$(git status --porcelain -- ledger 2>/dev/null)"
  if [[ -n "$dirty" ]]; then
    echo "Unsaved changes in ledger/ (an operation's record was not committed/pushed):"
    sed 's/^/    /' <<<"$dirty"
    echo "ADVICE: if those files are what you expect, save them with:"
    echo "        git add -A -- ledger && git commit -m 'ledger: recover' -- ledger && git push $GIT_REMOTE $GIT_BRANCH"
  fi
  ahead="$(git rev-list --count "$GIT_REMOTE/$GIT_BRANCH..HEAD" 2>/dev/null || echo 0)"
  if (( ahead > 0 )); then
    echo "You have $ahead commit(s) not pushed to $GIT_REMOTE/$GIT_BRANCH."
    echo "ADVICE: git log --oneline $GIT_REMOTE/$GIT_BRANCH..HEAD   (look), then: git push $GIT_REMOTE $GIT_BRANCH"
  fi
  [[ -z "$dirty" && "$ahead" == 0 ]] && echo "Git: ledger/ is clean and nothing is waiting to be pushed (as of the last fetch)."
  echo "(Run 'make sync' to fetch teammates' latest records.)"
fi

if [[ -f runtime/active-session.env ]]; then
  echo
  echo "Legacy file runtime/active-session.env exists (old Makefile format). It is NOT used any more."
  echo "Its contents (shown as text, never executed):"
  head -n 10 runtime/active-session.env | sanitize | sed 's/^/    /'
  echo "ADVICE: once you know the real AWS state (above), remove it with: git rm runtime/active-session.env"
fi
echo
echo "To stop a running instance that has no record: make stop (it is recorded as an untracked session)."
