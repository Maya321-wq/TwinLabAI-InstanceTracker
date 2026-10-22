#!/usr/bin/env bash
# Harmless WSL launch target for `make reminder-test`; no AWS or email calls.
set -u
printf 'WSL test command ran in distro %s at %s\n' "${WSL_DISTRO_NAME:-unknown}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
