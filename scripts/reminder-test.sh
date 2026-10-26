#!/usr/bin/env bash
# Register, run, and remove a harmless Windows scheduled task to verify WSL integration.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
need_config

[[ -n "${WSL_DISTRO_NAME:-}" ]] || die 2 "Run this command from WSL; WSL_DISTRO_NAME is not set."
command -v powershell.exe >/dev/null 2>&1 || die 2 "powershell.exe was not found on PATH."
command -v wslpath >/dev/null 2>&1 || die 2 "wslpath was not found on PATH."
task_script="$(wslpath -w "$TW_ROOT/scripts/windows/reminder-task.ps1")" || die 2 "Could not convert the Task Scheduler script path."

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$task_script" \
  -Mode SelfTest -Distro "$WSL_DISTRO_NAME" -RepoPath "$TW_ROOT" \
  || die 1 "Windows Task Scheduler test failed."
