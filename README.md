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

### Gmail notifications (optional, configured separately on each computer)
After a verified, recorded start or stop, the command can email the configured team and supervisor with the operator,
instance ID, region, instance type, state, public IP (when available), and operation ID. After a successful start, the
starter's WSL computer can send that operator a reminder `REMINDER_MINUTES` (default `240`, i.e. 4 hours) after AWS
launch time, but only if AWS still reports the same instance launch as running.

Each teammate configures their own sender and recipient list in their ignored `config/twinlab.env`:

```text
GMAIL_ADDRESS=your-sending-account@gmail.com
NOTIFY_EMAILS=member1@example.com,member2@example.com,supervisor@example.com
OPERATOR_EMAIL=your-own-address@example.com
REMINDER_MINUTES=240
```

`NOTIFY_EMAILS` should contain all teammates and the supervisor; give this list to each teammate separately because it
is not committed to Git. Each operator's `OPERATOR_EMAIL` is their personal reminder destination. Set `REMINDER_BACKEND=windows` to use Windows Task Scheduler
from WSL, or `local` to keep a WSL background timer. Set `REMINDER_MINUTES=5` temporarily for a quick running-time
reminder test, or keep the default `240` for 4 hours. The Gmail sending
account must have 2-Step Verification and a Google App Password. Store the App Password outside the repo in WSL:

Set `EMAIL_NOTIFICATIONS=off` in the local config to disable start, stop, and reminder emails without changing the
AWS start/stop workflow. Set it back to `on` to re-enable emails. The default is `on` for existing configs.

```bash
mkdir -p ~/.config/twinlab-ops
chmod 700 ~/.config/twinlab-ops
read -rsp "Gmail App Password: " TWINLAB_APP_PASSWORD; printf '\n'
printf '%s' "$TWINLAB_APP_PASSWORD" > ~/.config/twinlab-ops/gmail-app-password
unset TWINLAB_APP_PASSWORD
chmod 600 ~/.config/twinlab-ops/gmail-app-password
```

Use a dedicated TwinLab sender account if possible; never commit or share an App Password in Git or chat. Then verify
email delivery without touching AWS:

```bash
make validate                 # reports whether notification settings are ready
make notify-test              # sends a test email to the configured team
make reminder-test            # verifies Windows Task Scheduler can run WSL; no AWS/email
```

Email delivery is best effort: a mail failure is reported, but does not undo a successful AWS operation or ledger
record. `make notify-test` can verify delivery; it does not resend a missed start/stop notice.

`make reminder-test` registers a temporary task, runs a harmless WSL command through Windows Task Scheduler, and
removes the task. It does not call AWS or send email, so it is safe to run while the EC2 instance is stopped.

With `REMINDER_BACKEND=windows`, Windows Task Scheduler registers a one-time task at the AWS launch time plus the
configured reminder interval. It requests wake-from-sleep, start-when-available, and retries failed runs, then
launches WSL to check AWS and email the operator. If the PC is off, logged out, or offline at the scheduled time,
delivery can still be late or unavailable; a local scheduler cannot guarantee delivery like a central service. The
original `local` backend instead uses a WSL background process and can be missed if WSL exits. In either mode, the
reminder rechecks AWS and discards the alert if the original instance launch is no longer running.

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
| `make notify-test` | no | sends a test email to the configured notification list |
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
scripts/                   command scripts; lib/common.sh (AWS + config), lib/ledger.sh (claims + Git), lib/notify.sh (Gmail)
tools/ledger.py            standard-library Python: records, history, diagnosis
tools/notify.py            standard-library Python: Gmail SMTP notifications
ledger/                    shared records: claim.json (current operation) and events/*.json (one file per event)
tests/                     fake aws/git, sandboxed harness, scenario tests (run with: make test)
```
Records are one small JSON file per event, so Git never produces merge conflicts. `make history` derives sessions
from them and shows gaps instead of inventing times.

## 6. Not included yet (kept out on purpose)
Cost estimates and reports, resource inventory (disks, Elastic IPs), CARLA and experiment tracking, idle alerts beyond
the configured running-time reminder.
The `ledger/` events carry `instance_type` and timestamps, so a cost report can be added later without changing the records.
