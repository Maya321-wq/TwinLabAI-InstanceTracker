#!/usr/bin/env bash
# Ledger + claim-before-act coordination. Source AFTER common.sh and load_config.
#
# How coordination works (COORDINATION=git):
#   1. precheck : right branch, ledger/ clean, nothing unpushed, fast-forward to latest
#   2. claim    : write ledger/claim.json + an "intent" event, commit ONLY ledger/, push
#                 -> if the push is rejected someone else got there first: roll back, touch nothing in AWS
#   3. act      : only now call AWS, then verify the real state
#   4. finish   : write a "result" event, remove the claim, commit ONLY ledger/, push
# A successful push proves only that a record was saved. It never proves what AWS did.

ledger() { python3 -I "$TW_TOOLS/ledger.py" --dir "$LEDGER_DIR" "$@"; }

LAST_GIT_ERROR=""
CLAIM_HELD=0

# Run git; on failure keep a sanitized copy of its output in LAST_GIT_ERROR.
_git() {
  local out rc
  out="$(git "$@" 2>&1)"; rc=$?
  (( rc != 0 )) && LAST_GIT_ERROR="$(sanitize <<<"$out" | head -c 500)"
  return $rc
}

ledger_precheck() {
  mkdir -p "$LEDGER_DIR/events"
  if [[ "$COORDINATION" == local ]]; then
    warn "COORDINATION=local: claims only protect THIS computer, not your teammates."
    return 0
  fi
  _git rev-parse --is-inside-work-tree || { err "Not inside a Git work tree ($LAST_GIT_ERROR). Run from your clone of the repo, or set COORDINATION=local (no team protection)."; return 1; }
  _git remote get-url "$GIT_REMOTE" || { err "Git remote '$GIT_REMOTE' is not configured, so teammates cannot be coordinated. Add it (git remote add $GIT_REMOTE <url>) or set COORDINATION=local."; return 1; }
  local branch ahead behind
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [[ "$branch" == "$GIT_BRANCH" ]] || { err "You are on branch '$branch'; ledger records must go to '$GIT_BRANCH'. Run: git switch $GIT_BRANCH"; return 1; }
  if [[ -n "$(git status --porcelain -- ledger 2>/dev/null)" ]]; then
    err "ledger/ has uncommitted changes (an earlier operation may not have been saved). Run: make recover"; return 1
  fi
  _git fetch "$GIT_REMOTE" || { err "git fetch failed (network or access problem): $LAST_GIT_ERROR"; return 1; }
  ahead="$(git rev-list --count "$GIT_REMOTE/$GIT_BRANCH..HEAD" 2>/dev/null)" || { err "Remote branch $GIT_REMOTE/$GIT_BRANCH not found. Push the branch once first."; return 1; }
  behind="$(git rev-list --count "HEAD..$GIT_REMOTE/$GIT_BRANCH" 2>/dev/null)" || behind=0
  [[ "$ahead" =~ ^[0-9]+$ && "$behind" =~ ^[0-9]+$ ]] || { err "Unexpected answer from git when comparing with $GIT_REMOTE/$GIT_BRANCH (ahead='$ahead' behind='$behind'). Nothing was changed."; return 1; }
  if (( ahead > 0 )); then
    err "You have $ahead local commit(s) that are not pushed. Recording an operation pushes the branch, so push or move them first (see: make recover). A clone used only for operations avoids this."; return 1
  fi
  if (( behind > 0 )); then
    _git pull --ff-only "$GIT_REMOTE" "$GIT_BRANCH" || { err "Could not fast-forward to the latest shared records: $LAST_GIT_ERROR"; return 1; }
  fi
  return 0
}

# publish "<message>": commit ONLY ledger/ and push. 0 ok, 1 commit failed, 2 push failed.
publish() {
  [[ "$COORDINATION" == local ]] && return 0
  _git add -A -- ledger || return 1
  _git commit -q -m "$1" -- ledger || return 1
  _git push "$GIT_REMOTE" "$GIT_BRANCH" || return 2
  return 0
}

# Undo OUR OWN unpublished claim commit. Only moves HEAD back to where it was before we
# committed (working files of other work are untouched), then deletes the two files we created.
rollback_claim() {
  local prev="$1"
  if [[ "$COORDINATION" == git && -n "$prev" ]]; then
    _git reset -q --mixed "$prev" || warn "could not reset index: $LAST_GIT_ERROR"
  fi
  ledger claim-discard --op-id "$OP_ID" >/dev/null 2>&1 || true
}

# ledger_acquire <action> [key=value ...]  (needs OP_ID HOST OPERATOR). Returns 0 only when the claim is PUBLISHED.
ledger_acquire() {
  local action="$1"; shift
  local prev="" out rc
  ledger_precheck || return 1
  [[ "$COORDINATION" == git ]] && prev="$(git rev-parse HEAD 2>/dev/null)"
  out="$(ledger claim-acquire --op-id "$OP_ID" --action "$action" --operator "$OPERATOR" --host "$HOST" \
         --ttl-minutes "$CLAIM_TTL_MINUTES" instance_id="$INSTANCE_ID" region="$REGION" "$@" 2>&1)"; rc=$?
  case $rc in
    0) ;;
    10) err "$out"; err "Another operation is in progress. Nothing was changed. Wait for it or ask that teammate."; return 1;;
    11) err "$out"; err "A stale claim exists (its operation never finished). Nothing was changed. Run: make recover"; return 1;;
    12) err "$out"; err "The claim file is unreadable. Nothing was changed. Run: make recover"; return 1;;
    *)  err "$out"; return 1;;
  esac
  publish "ledger: claim $action ($OP_ID) by $OPERATOR"; rc=$?
  if (( rc != 0 )); then
    rollback_claim "$prev"
    if (( rc == 2 )); then
      err "Could not publish the claim: $LAST_GIT_ERROR"
      err "A teammate probably claimed first, or the network failed. Nothing was changed in AWS. Run 'make sync' and 'make status', then try again."
    else
      err "Could not commit the claim: $LAST_GIT_ERROR"
    fi
    return 1
  fi
  CLAIM_HELD=1
  return 0
}

# ledger_finish key=value ... : result event + release claim + publish. Returns 3 if the record is incomplete.
ledger_finish() {
  ledger event-add --op-id "$OP_ID" --action "$ACTION" --kind result --operator "$OPERATOR" --host "$HOST" \
      instance_id="$INSTANCE_ID" region="$REGION" aws_caller_arn="${CALLER_ARN:-unknown}" "$@" >/dev/null || return 3
  ledger claim-release --op-id "$OP_ID" >/dev/null || return 3
  publish "ledger: $ACTION result ($OP_ID) by $OPERATOR" || return 3
  return 0
}

# finish_op <outcome> <exit-code> <error-text> [key=value ...]  -> records the result and exits.
finish_op() {
  local outcome="$1" code="$2" etxt="${3:-}"; shift 3
  if [[ "$CLAIM_HELD" == 1 ]]; then
    if ! ledger_finish outcome="$outcome" observed_state="${AWS_STATE:-unknown}" instance_type="${AWS_TYPE:-}" error="$etxt" "$@"; then
      err "AWS side: outcome=$outcome, last observed state='${AWS_STATE:-unknown}'."
      err "BUT the record of this operation was NOT fully saved or pushed. ${LAST_GIT_ERROR:-}"
      err "Do NOT repeat the command. Run: make recover   (it prints the exact next steps)"
      exit 3
    fi
  fi
  exit "$code"
}

# fail_op "<message>": print the error, record a failed result, exit 1.
fail_op() { err "$1"; finish_op failed 1 "$1"; }
