# TwinLab Ops - the front door for managing the shared EC2 instance.
#
# This file stays THIN on purpose. All logic lives in scripts/ and tools/.
# Dry-run safety: no recipe calls $(MAKE), uses $(shell ...), or starts with "+".
# So `make -n <target>` only PRINTS the one script line; it can never run AWS or Git.
# (tests/test_dryrun.sh checks this.) The old Makefile is kept as Makefile.v2.backup.

SHELL := /bin/bash
.DEFAULT_GOAL := help

define HELP_TEXT
TwinLab Ops - shared EC2 instance. Run from WSL inside this repo.

READ-ONLY (never changes AWS or Git):
  make help        this list
  make validate    check tools, config, AWS login and the target instance
  make status      state, type, IP, current claim, last tracked start
  make type        show the instance type
  make uptime      how long it has been running (AWS-reported)
  make dcv         print the DCV URL if the instance is running
  make history     sessions and operations from the local records
  make recover     diagnose mismatches between AWS, records and Git; prints next steps
  make test        run the mock-only tests (no AWS, no remote Git)

CHANGES LOCAL FILES / GIT ONLY (never AWS):
  make configure   create a NAMED AWS profile (PROFILE=twinlab); never touches "default"
  make sync        fast-forward to teammates' latest records
  make clear-claim remove a STALE claim after you confirm

CHANGES AWS (asks for confirmation, records who/what/when, verifies the result):
  make start                 start the instance
  make stop                  stop it (disconnects every DCV user)
  make set-type TYPE=<type>  change type; instance must already be stopped

Settings: config/twinlab.env   Available types: config/instance-types.txt
Script exit codes: 0 ok, 1 refused/failed, 2 setup problem, 3 AWS done but record not saved, 4 timed out
(make itself reports any failure as exit 2 and prints the script's code as 'Error N')
endef
export HELP_TEXT

.PHONY: help validate status type uptime dcv start stop set-type history recover clear-claim configure sync test

help: ; @printf '%s\n' "$$HELP_TEXT"

validate:    ; @bash scripts/validate.sh
status:      ; @bash scripts/status.sh status
type:        ; @bash scripts/status.sh type
uptime:      ; @bash scripts/status.sh uptime
dcv:         ; @bash scripts/status.sh dcv
history:     ; @bash scripts/history.sh
recover:     ; @bash scripts/recover.sh
test:        ; @bash tests/run.sh

configure:   ; @bash scripts/configure.sh
sync:        ; @bash scripts/sync.sh
clear-claim: ; @bash scripts/clear-claim.sh

start:       ; @bash scripts/start.sh
stop:        ; @bash scripts/stop.sh
set-type:    ; @bash scripts/set-type.sh
