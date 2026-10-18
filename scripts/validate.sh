#!/usr/bin/env bash
# make validate - checks tools, config and the target instance. READ-ONLY:
# it only reads files and makes two AWS read calls (who am I, describe the instance).
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

fails=0
ok()   { printf '[ OK ] %s\n' "$*"; }
bad()  { printf '[FAIL] %s\n' "$*"; fails=$((fails+1)); }
note() { printf '[WARN] %s\n' "$*"; }

for t in aws python3; do
  if command -v "$t" >/dev/null 2>&1; then ok "tool found: $t"; else bad "tool missing: $t"; fi
done
if (( BASH_VERSINFO[0] >= 4 )); then ok "bash ${BASH_VERSION%%(*}"; else bad "bash 4 or newer is required"; fi

if load_config; then
  ok "config parsed: instance $INSTANCE_ID, region $REGION, coordination=$COORDINATION"
  if [[ -n "$OPERATOR" ]]; then ok "operator (self-declared, not verified): $OPERATOR"
  else note "OPERATOR is not set: start/stop/set-type/clear-claim will refuse until you set it"; fi
  if [[ -n "$TW_PROFILE" ]]; then ok "AWS profile from config: $TW_PROFILE"
  else note "AWS_PROFILE is empty: the AWS CLI's current default credentials/profile are used"; fi

  if load_allowlist; then
    ok "instance-types.txt: ${#ALLOW_APPROVED[@]} approved, ${#ALLOW_PENDING[@]} UNCONFIRMED"
    (( ${#ALLOW_APPROVED[@]} > 0 )) || note "no approved types yet: make set-type cannot be used until you confirm some with your supervisor"
  else bad "allowlist: $ALLOWLIST_ERROR"; fi

  if command -v aws >/dev/null 2>&1; then
    if arn="$(aws_cmd sts get-caller-identity --query Arn --output text 2>/dev/null)" && [[ -n "$arn" ]]; then
      ok "AWS credentials work (caller: $arn)"
      note "everyone shares one key, so this identity does not tell teammates apart"
    else bad "AWS credentials did not work (check 'aws configure list', your profile, and your network)"; fi
    if read_instance; then ok "instance found: state=$AWS_STATE type=$AWS_TYPE"
    else bad "cannot read $INSTANCE_ID in $REGION: $LAST_AWS_ERROR"; fi
  fi

  if [[ "$COORDINATION" == git ]]; then
    if command -v git >/dev/null 2>&1; then
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        ok "inside a Git work tree"
        git remote get-url "$GIT_REMOTE" >/dev/null 2>&1 && ok "remote '$GIT_REMOTE' configured" || bad "remote '$GIT_REMOTE' is not configured (add it, or use COORDINATION=local)"
        branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
        [[ "$branch" == "$GIT_BRANCH" ]] && ok "on branch $GIT_BRANCH" || bad "on branch '$branch' but GIT_BRANCH is '$GIT_BRANCH'"
      else bad "not inside a Git work tree (needed for COORDINATION=git)"; fi
    else bad "tool missing: git (needed for COORDINATION=git)"; fi
  else
    note "COORDINATION=local: claims protect only this computer, NOT your teammates"
  fi
else
  bad "config: $CONFIG_ERROR"
fi

echo
if (( fails == 0 )); then echo "All checks passed."; exit 0; fi
echo "$fails check(s) failed."; exit 1
