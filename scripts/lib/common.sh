#!/usr/bin/env bash
# Shared helpers for all TwinLab Ops scripts. Source this file; do not run it.
#
# Safety rules implemented here:
#   * Config is PARSED as KEY=VALUE text and validated. It is never `source`d.
#   * Every AWS call goes through aws_cmd, which always passes --region.
#   * Nothing here prints credentials; AWS error text is passed through sanitize().

TW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TW_TOOLS="$TW_ROOT/tools"
cd "$TW_ROOT" || exit 2

# Exit codes used by the commands:
#   0 ok / nothing to do   1 refused or failed   2 bad config or setup
#   3 AWS part finished but the RECORD was not saved/pushed   4 timed out waiting for AWS

info() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }
die()  { local code="$1"; shift; err "$*"; exit "$code"; }

utc_now()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
new_op_id() { printf 'op-%s-%04x' "$(date -u +%Y%m%dT%H%M%SZ)" "$((RANDOM % 65536))"; }

# Remove anything that looks like a credential from text coming from AWS/Git.
sanitize() {
  sed -E \
    -e 's/(AKIA|ASIA|AIDA|AROA)[A-Z0-9]{12,}/[REDACTED-KEY-ID]/g' \
    -e 's/([Ss]ecret[A-Za-z_ -]*|[Ss]ession[ _-]?[Tt]oken)([=: ]+)[^[:space:]]+/\1\2[REDACTED]/g' \
    -e 's#(^|[^A-Za-z0-9/+])[A-Za-z0-9/+]{40}($|[^A-Za-z0-9/+])#\1[REDACTED-40]\2#g'
}

# ---------------------------------------------------------------- config ----
TW_ALLOWED_KEYS=" INSTANCE_ID REGION OPERATOR AWS_PROFILE COORDINATION GIT_REMOTE GIT_BRANCH CLAIM_TTL_MINUTES WAIT_TIMEOUT_SECONDS POLL_SECONDS "

# load_config: returns 0 and sets globals, or returns 1 with CONFIG_ERROR set.
load_config() {
  local file="${TWINLAB_CONFIG:-$TW_ROOT/config/twinlab.env}" line key val n=0
  declare -A cfg=() seen=()
  CONFIG_ERROR=""
  [[ -f "$file" ]] || { CONFIG_ERROR="Config file not found: $file. Run: cp config/twinlab.env.example config/twinlab.env  (then edit it)"; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n+1)); line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ ! "$line" =~ ^([A-Z_]+)=(.*)$ ]]; then CONFIG_ERROR="$file line $n: expected KEY=VALUE"; return 1; fi
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    [[ "$TW_ALLOWED_KEYS" == *" $key "* ]] || { CONFIG_ERROR="$file line $n: unknown setting '$key'"; return 1; }
    [[ -z "${seen[$key]:-}" ]] || { CONFIG_ERROR="$file line $n: '$key' is set twice (ambiguous)"; return 1; }
    seen[$key]=1
    if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
    cfg[$key]="$val"
  done <"$file"

  INSTANCE_ID="${cfg[INSTANCE_ID]:-}"; REGION="${cfg[REGION]:-}"; OPERATOR="${cfg[OPERATOR]:-}"
  TW_PROFILE="${cfg[AWS_PROFILE]:-}"; COORDINATION="${cfg[COORDINATION]:-git}"
  GIT_REMOTE="${cfg[GIT_REMOTE]:-origin}"; GIT_BRANCH="${cfg[GIT_BRANCH]:-main}"
  CLAIM_TTL_MINUTES="${cfg[CLAIM_TTL_MINUTES]:-60}"
  WAIT_TIMEOUT_SECONDS="${cfg[WAIT_TIMEOUT_SECONDS]:-600}"; POLL_SECONDS="${cfg[POLL_SECONDS]:-15}"

  [[ "$INSTANCE_ID" =~ ^i-[0-9a-f]{8}([0-9a-f]{9})?$ ]] || { CONFIG_ERROR="INSTANCE_ID is missing or not a valid EC2 instance id (got '$INSTANCE_ID')"; return 1; }
  [[ "$REGION" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || { CONFIG_ERROR="REGION is missing or invalid (got '$REGION'); expected e.g. us-west-2"; return 1; }
  [[ -z "$TW_PROFILE" || "$TW_PROFILE" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || { CONFIG_ERROR="AWS_PROFILE has invalid characters"; return 1; }
  [[ -z "$OPERATOR" || "$OPERATOR" =~ ^[A-Za-z0-9._-]{2,32}$ ]] || { CONFIG_ERROR="OPERATOR must be 2-32 characters: letters, digits, . _ -"; return 1; }
  [[ "$COORDINATION" == git || "$COORDINATION" == local ]] || { CONFIG_ERROR="COORDINATION must be 'git' or 'local'"; return 1; }
  [[ "$GIT_REMOTE" =~ ^[A-Za-z0-9._-]+$ ]] || { CONFIG_ERROR="GIT_REMOTE has invalid characters"; return 1; }
  [[ "$GIT_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || { CONFIG_ERROR="GIT_BRANCH has invalid characters"; return 1; }
  [[ "$CLAIM_TTL_MINUTES" =~ ^[0-9]+$ ]] && (( CLAIM_TTL_MINUTES >= 5 && CLAIM_TTL_MINUTES <= 720 )) || { CONFIG_ERROR="CLAIM_TTL_MINUTES must be 5..720"; return 1; }
  [[ "$WAIT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] && (( WAIT_TIMEOUT_SECONDS >= 1 && WAIT_TIMEOUT_SECONDS <= 3600 )) || { CONFIG_ERROR="WAIT_TIMEOUT_SECONDS must be 1..3600"; return 1; }
  [[ "$POLL_SECONDS" =~ ^[0-9]+$ ]] && (( POLL_SECONDS >= 1 && POLL_SECONDS <= 60 )) || { CONFIG_ERROR="POLL_SECONDS must be 1..60"; return 1; }

  if [[ "$COORDINATION" == git ]]; then LEDGER_DIR="$TW_ROOT/ledger"; else LEDGER_DIR="$TW_ROOT/local/ledger"; fi
  return 0
}
need_config()      { load_config || die 2 "$CONFIG_ERROR"; }
require_operator() { [[ -n "$OPERATOR" ]] || die 2 "OPERATOR is not set in the config. Add your team username (self-declared) before using this command."; }

# ------------------------------------------------------------ allowlist -----
# Fills ALLOW_TYPES and ALLOW_APPROVAL_REQUIRED from the configured type list.
load_allowlist() {
  local file="${TWINLAB_TYPES_FILE:-$TW_ROOT/config/instance-types.txt}" line n=0 t status extra
  ALLOW_TYPES=(); ALLOW_APPROVAL_REQUIRED=(); ALLOWLIST_ERROR=""
  [[ -f "$file" ]] || { ALLOWLIST_ERROR="Allowlist not found: $file"; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n+1)); line="${line%$'\r'}"; line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    read -r t status extra <<<"$line"
    [[ -z "$extra" ]] || { ALLOWLIST_ERROR="$file line $n: expected an instance type and optional APPROVAL_REQUIRED marker"; return 1; }
    [[ "$t" =~ ^(t3|g4dn|g5)\.[a-z0-9]+$ ]] || { ALLOWLIST_ERROR="$file line $n: '$t' is not a supported t3/g4dn/g5 instance type"; return 1; }
    case "$status" in
      "")                  ALLOW_TYPES+=("$t");;
      APPROVAL_REQUIRED)   ALLOW_APPROVAL_REQUIRED+=("$t");;
      *) ALLOWLIST_ERROR="$file line $n: status must be APPROVAL_REQUIRED when present"; return 1;;
    esac
  done <"$file"
  (( ${#ALLOW_TYPES[@]} + ${#ALLOW_APPROVAL_REQUIRED[@]} > 0 )) || { ALLOWLIST_ERROR="$file: no instance types are listed"; return 1; }
  return 0
}

# ------------------------------------------------------------------ AWS -----
aws_cmd() {
  local a=(--region "$REGION")
  [[ -n "$TW_PROFILE" ]] && a+=(--profile "$TW_PROFILE")
  aws "${a[@]}" "$@"
}

# read_instance: sets AWS_STATE AWS_TYPE AWS_IP AWS_LAUNCH AWS_AZ, or returns 1 with LAST_AWS_ERROR.
read_instance() {
  local out rc errf; errf="$(mktemp)"
  out="$(aws_cmd ec2 describe-instances --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].[State.Name,InstanceType,PublicIpAddress,LaunchTime,Placement.AvailabilityZone]' \
        --output text 2>"$errf")"; rc=$?
  if (( rc != 0 )); then LAST_AWS_ERROR="$(sanitize <"$errf" | head -c 400)"; rm -f "$errf"; return 1; fi
  rm -f "$errf"
  IFS=$'\t' read -r AWS_STATE AWS_TYPE AWS_IP AWS_LAUNCH AWS_AZ <<<"$out"
  if [[ -z "${AWS_STATE:-}" || "$AWS_STATE" == None ]]; then LAST_AWS_ERROR="AWS returned no data for $INSTANCE_ID in $REGION"; return 1; fi
  [[ "${AWS_IP:-}" == None ]] && AWS_IP=""
  return 0
}

# wait_for_state <state>: 0 reached, 4 timed out (we poll ourselves so the timeout is ours).
wait_for_state() {
  local target="$1" attempts i
  attempts=$(( WAIT_TIMEOUT_SECONDS / POLL_SECONDS )); (( attempts < 1 )) && attempts=1
  for (( i=1; i<=attempts; i++ )); do
    if read_instance; then
      [[ "$AWS_STATE" == "$target" ]] && return 0
    else
      warn "could not read state (attempt $i/$attempts): $LAST_AWS_ERROR"
    fi
    (( i < attempts )) && sleep "$POLL_SECONDS"
  done
  return 4
}

resolve_caller() {
  local out
  out="$(aws_cmd sts get-caller-identity --query Arn --output text 2>/dev/null)" && [[ -n "$out" ]] && CALLER_ARN="$out" || CALLER_ARN="unknown"
}

confirm() {  # confirm "<prompt>" <exact word that must be typed>
  local reply; printf '%s ' "$1" >&2
  IFS= read -r reply || reply=""
  [[ "$reply" == "$2" ]]
}

print_instance_summary() {
  info "Instance : $INSTANCE_ID ($REGION)"
  info "State    : $AWS_STATE"
  info "Type     : $AWS_TYPE"
}
