#!/usr/bin/env bash
# make configure [PROFILE=twinlab] - creates a NAMED AWS CLI profile using the AWS CLI's own prompts.
#   * It never touches the "default" profile.
#   * Keys are typed into the AWS CLI itself: they are never a command-line argument,
#     never written to this repo, and never printed by this script.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
profile="${PROFILE:-twinlab}"
[[ "$profile" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die 2 "PROFILE has invalid characters."
[[ "$profile" != default ]] || die 2 "Refusing to write the 'default' profile: it would overwrite the credentials your current commands use. Pick another name."
command -v aws >/dev/null 2>&1 || die 2 "The AWS CLI is not installed."

if aws configure list-profiles 2>/dev/null | grep -qx "$profile"; then
  warn "A profile named '$profile' already exists and will be updated."
  confirm "Type 'yes' to continue:" yes || { info "Cancelled. Nothing was changed."; exit 1; }
fi
info "This runs:  aws configure --profile $profile"
info "It writes only the [$profile] sections of ~/.aws/credentials and ~/.aws/config."
info "Enter the key your supervisor gave you when the AWS CLI asks. Region: us-west-2. Output: json."
info "If your terminal shows what you type, run 'clear' afterwards."
aws configure --profile "$profile" || die 1 "aws configure failed."
info
info "Next: set  AWS_PROFILE=$profile  in config/twinlab.env, then run: make validate"
info "Your existing default profile was not modified."
