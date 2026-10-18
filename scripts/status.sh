#!/usr/bin/env bash
# make status | type | uptime | dcv - READ-ONLY views of the instance (one AWS describe call).
# Usage: status.sh [status|type|uptime|dcv]
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/ledger.sh"
mode="${1:-status}"
need_config
read_instance || die 1 "Cannot read the instance from AWS: $LAST_AWS_ERROR"

case "$mode" in
  status)
    print_instance_summary
    [[ -n "$AWS_IP" ]] && info "Public IP: $AWS_IP"
    if [[ "$AWS_STATE" == running ]]; then
      info "Running since (AWS LaunchTime): $AWS_LAUNCH   (up $(ledger uptime --since "$AWS_LAUNCH"))"
    fi
    ledger claim-show || true
    last="$(ledger last-start)"
    info "Last tracked start: $last"
    if [[ "$AWS_STATE" == running && "$last" == none ]]; then
      warn "running but no tracked start (started outside these tools, or run 'make sync'). See: make recover"
    fi
    ;;
  type)
    info "$INSTANCE_ID  $AWS_TYPE"
    ;;
  uptime)
    info "Current state : $AWS_STATE"
    if [[ "$AWS_STATE" == running ]]; then
      info "Running since : $AWS_LAUNCH (AWS-reported)"
      info "Running for   : $(ledger uptime --since "$AWS_LAUNCH")"
      info "Type          : $AWS_TYPE"
      info "Last tracked start: $(ledger last-start)"
    else
      info "The instance is not running."
    fi
    ;;
  dcv)
    if [[ "$AWS_STATE" == running && -n "$AWS_IP" ]]; then
      info "DCV URL: https://$AWS_IP:8443"
      info "(the address can change after a stop/start unless the instance has an Elastic IP)"
    else
      info "No DCV URL: state is '$AWS_STATE' and the public IP is '${AWS_IP:-none}'."
    fi
    ;;
  *) die 2 "unknown mode '$mode'";;
esac
