# TwinLab Ops

A small tool for managing our **one shared EC2 instance** from WSL: check it, start it, stop it,
and change its type, while keeping a shared record of who did what and when.

It does **not** manage DCV, CARLA, ROS 2 or experiments (those can be added later), and it does **not**
calculate costs yet. Stopping the instance stops compute charges, but disks and other resources can still cost money.

> **Read this first.** Everyone shares one AWS key, so AWS cannot tell us apart. The `OPERATOR` name in the
> records is *self-declared*. It is good for coordination between friends, not proof of identity.

## 1. First-time setup (once per teammate, in WSL)

```bash
# Prerequisites: bash 4+, make, python3, git, and the AWS CLI
sudo apt update && sudo apt install -y make python3 git     # AWS CLI: see AWS's install guide
git clone <our repo url> twinlab-ops && cd twinlab-ops       # clone INSIDE WSL (e.g. ~/twinlab-ops), not /mnt/c

cp config/twinlab.env.example config/twinlab.env
nano config/twinlab.env       # set INSTANCE_ID (the one you verified), OPERATOR (your name)
make validate                 # read-only check; fix every [FAIL] before going on
make test                     # mock-only tests; they never touch AWS or our real Git remote
```

`config/twinlab.env` is ignored by Git. Never put AWS keys in it.

### AWS credentials: nothing changes unless you choose to
Out of the box the tool uses whatever your AWS CLI uses **today** (the `default` profile), exactly like the old Makefile.
To keep this separate from other projects on your machine, you can optionally migrate to a named profile:

```bash
make configure                # runs: aws configure --profile twinlab   (never touches "default")
# then in config/twinlab.env set:   AWS_PROFILE=twinlab
make validate
```
The AWS CLI asks for the key itself; it is never a command-line argument or written to this repo. Your `default`
profile stays as it was, so you can go back by emptying `AWS_PROFILE`. Whether the team should keep sharing one key is
your supervisor's decision; this tool works either way. (Individual keys would make the records more trustworthy.)

### Available instance types
`config/instance-types.txt` lists the types available in `make set-type`: `t3.small`, `t3.medium`, `t3.large`,
`t3.xlarge`, `g4dn.xlarge`, `g4dn.2xlarge`, and `g5.xlarge`. The `g5.xlarge` entry is marked
`APPROVAL_REQUIRED`, so it is shown but cannot be selected until the supervisor approves it. After approval,
remove that marker from the entry and commit the change. Before changing any instance type, the tool checks whether
AWS offers it in the instance's Availability Zone.

## 2. Daily commands

| Command | Changes AWS? | What it does |
|---|---|---|
| `make status` | no | state, type, IP, current claim, last tracked start |
| `make uptime` / `type` / `dcv` | no | uptime, type, DCV URL (only when running) |
| `make history` | no | sessions + operations from your local copy of the records |
| `make sync` | no | fast-forward to teammates' latest records |
| `make recover` | no | explains any mismatch between AWS, records and Git, with exact next steps |
| `make start` | **yes** | confirm, claim, start, verify it is `running`, record |
| `make stop` | **yes** | warns, you type `STOP`, claim, stop, verify `stopped`, record |
| `make set-type TYPE=t3.medium` | **yes** | only when **stopped**; confirm, claim, change, verify, record. Never stops or starts anything |
| `make clear-claim` | no | removes a *stale* claim after you confirm |
| `make validate` / `make test` / `make help` | no | checks and help |

Typical day:

```bash
make sync && make status      # who is using it? is anyone mid-operation?
make start                    # tell your teammates first; DCV may need ~1 minute after "running"
make dcv                      # prints the DCV URL
# ... work ...
make stop                     # ONLY after everyone agrees: it disconnects every DCV user
```
Changing type: agree with the team, make sure the instance is stopped, then `make set-type TYPE=g4dn.xlarge`, followed by `make start` if needed.
The tool cannot check that our machine image and GPU drivers work on a new type; it warns, you decide.

## 3. How the safety works

* **Claim before act.** Before AWS is touched, the command writes `ledger/claim.json`, commits only `ledger/`, and
  **pushes**. If the push is rejected, someone else claimed first: the command undoes its own local commit and exits
  with AWS untouched. Then it acts, verifies the real AWS state (we poll ourselves, with our own timeout), and
  pushes a result record and removes the claim.
* **A pushed record is not proof of what AWS did**, and AWS is always the source of truth. `status` and `recover` compare them.
* **Nothing is retried automatically.** If AWS answers with an error, the tool checks whether the request still took effect.
* **Confirmations cannot be skipped** (there is no `YES=1`). Typing anything else, or having no terminal input, cancels.
* **Never terminates** the instance and never deletes disks or snapshots; those commands do not exist in the code.
* `make -n <target>` is safe: no recipe calls `$(MAKE)` or runs AWS/Git inline, so a dry run only prints the script line.
* Config and records are **parsed, never `source`d**; a bad file cannot run commands.

### Limits you should know
* Git coordination only protects people who use these commands and are online. It does not stop someone using the AWS
  console, the supervisor, or another tool. Always run `make status` first.
* Two people racing is handled by the push (one wins). If your repo cannot push to `main`, set `GIT_BRANCH` to a branch everyone can push to.
* `COORDINATION=local` (no remote yet) only protects against two terminals on **your own** computer; the tool says so every time.
* Records are only as complete as our use of the tool. An instance started elsewhere shows up as "no tracked start".
* Durations come from our own timestamps, not from AWS billing. This repo makes **no** cost claims.
* Operations take your local clock for event times; keep WSL's clock in sync (`date -u`).

### Exit codes (of the scripts; `make` itself prints "Error N" and exits 2)
`0` ok or nothing to do, `1` refused/failed, `2` setup problem, `3` **AWS finished but the record was not saved/pushed**
(do not repeat the command: run `make recover`), `4` timed out waiting for AWS (state may still change: `make status`).

## 4. When something goes wrong

| Symptom | Do this |
|---|---|
| `Another operation is in progress` | Wait, or ask that teammate. Nothing was changed. |
| `stale claim` / `unreadable` claim | `make recover`, check AWS state, then `make clear-claim` |
| Exit code 3, "record NOT fully saved" | `make recover` and run the git command it prints. Do **not** rerun the operation. |
| `uncommitted changes in ledger/` | `make recover` (a previous record was not saved) |
| `You are on branch ...` | `git switch main` |
| `You have N local commit(s) that are not pushed` | Push or move them; operations push the branch. Use a clone only for operations if this is annoying. |
| `AWS credentials did not work` | `aws configure list`; check `AWS_PROFILE`; ask your supervisor |
| Timed out | `make status`; the request may still finish |
| Old `runtime/active-session.env` or `runtime-history.csv` | Not used any more. History still prints the CSV; `make recover` explains the env file. |

## 5. Layout

```
Makefile                   thin front door (one script call per target)
Makefile.v2.backup         the original, untouched
config/                    twinlab.env.example, instance-types.txt (allowlist)
scripts/                   one script per command; lib/common.sh (AWS + config) and lib/ledger.sh (claims + Git)
tools/ledger.py            standard-library Python: records, history, diagnosis
ledger/                    shared records: claim.json (current operation) and events/*.json (one file per event)
tests/                     fake aws/git, sandboxed harness, scenario tests (run with: make test)
```
Records are one small JSON file per event, so Git never produces merge conflicts. `make history` derives sessions
from them and shows gaps instead of inventing times.

## 6. Not included yet (kept out on purpose)
Cost estimates and reports, resource inventory (disks, Elastic IPs), CARLA and experiment tracking, idle alerts.
The `ledger/` events carry `instance_type` and timestamps, so a cost report can be added later without changing the records.
