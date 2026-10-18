#!/usr/bin/env python3
"""TwinLab Ops ledger tool (standard library only).

The ledger is a directory of small JSON files:
  claim.json            the CURRENT in-flight operation (a lock with an expiry)
  events/<...>.json     one immutable file per event (never edited, so Git never conflicts)

Sessions shown by `history` are DERIVED from events. Missing information is shown as
missing; timestamps are never invented. Data files are only ever parsed as JSON.
"""
import argparse
import datetime as dt
import json
import os
import re
import sys

SCHEMA = 1
KINDS = {"intent", "result", "claim_cleared"}
ACTIONS = {"start", "stop", "set-type", "clear-claim"}
OUTCOMES = {"success", "failed", "timeout", "already", "cleared"}
FIELDS = {"instance_id", "region", "aws_caller_arn", "observed_state", "instance_type",
          "requested_type", "outcome", "error", "note", "aws_launch_time"}

SECRETS = [
    re.compile(r"(AKIA|ASIA|AIDA|AROA)[A-Z0-9]{12,}"),
    re.compile(r"(?i)(secret[\w -]*|session[ _-]?token)[=: ]+\S+"),
    re.compile(r"(?<![A-Za-z0-9/+])[A-Za-z0-9/+]{40}(?![A-Za-z0-9/+])"),
]


def now():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s):
    try:
        s = str(s).strip()
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        t = dt.datetime.fromisoformat(s)
        return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)
    except (ValueError, TypeError):
        return None


def scrub(text, limit=400):
    text = re.sub(r"[\r\n\t]+", " ", str(text))
    for rx in SECRETS:
        text = rx.sub("[REDACTED]", text)
    return text[:limit]


def human(seconds):
    seconds = int(seconds)
    return "%dh %02dm" % (seconds // 3600, (seconds % 3600) // 60)


def events_dir(d):
    return os.path.join(d, "events")


def claim_path(d):
    return os.path.join(d, "claim.json")


def write_json_atomic(path, obj):
    tmp = path + ".%d.tmp" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, sort_keys=True)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def kv_fields(pairs):
    out = {}
    for p in pairs or []:
        if "=" not in p:
            raise SystemExit("bad field (expected key=value): %s" % p)
        k, v = p.split("=", 1)
        if k not in FIELDS:
            raise SystemExit("unknown field: %s" % k)
        if v != "":
            out[k] = scrub(v)
    return out


def base_event(a, kind, extra):
    if kind not in KINDS:
        raise SystemExit("bad kind: %s" % kind)
    if a.action not in ACTIONS:
        raise SystemExit("bad action: %s" % a.action)
    ev = {"schema": SCHEMA, "ts_utc": iso(now()), "op_id": scrub(a.op_id), "action": a.action,
          "kind": kind, "operator_declared": scrub(a.operator), "operator_verified": False,
          "host": scrub(a.host)}
    ev.update(extra)
    if ev.get("outcome") and ev["outcome"] not in OUTCOMES:
        raise SystemExit("bad outcome: %s" % ev["outcome"])
    return ev


def save_event(d, ev):
    os.makedirs(events_dir(d), exist_ok=True)
    stamp = ev["ts_utc"].replace(":", "").replace("-", "")
    base = "%s-%s-%s-%s" % (stamp, ev["op_id"], ev["action"], ev["kind"])
    path, n = os.path.join(events_dir(d), base + ".json"), 1
    while os.path.exists(path):  # never overwrite an existing event
        n += 1
        path = os.path.join(events_dir(d), "%s-%d.json" % (base, n))
    write_json_atomic(path, ev)
    return path


def load_claim(d):
    """-> (status, data_or_message): none | active | stale | malformed"""
    p = claim_path(d)
    if not os.path.exists(p):
        return "none", None
    try:
        with open(p, encoding="utf-8") as f:
            c = json.load(f)
        exp = parse_iso(c["expires_utc"])
        for k in ("op_id", "action", "operator_declared", "created_utc"):
            if not isinstance(c.get(k), str):
                raise ValueError("missing " + k)
        if exp is None:
            raise ValueError("bad expires_utc")
    except (OSError, ValueError, KeyError, TypeError) as e:
        return "malformed", "claim.json is unreadable (%s)" % e
    return ("stale" if exp < now() else "active"), c


def describe_claim(status, c):
    if status == "none":
        return "Claim    : none"
    if status == "malformed":
        return "Claim    : UNREADABLE - %s" % c
    word = "ACTIVE" if status == "active" else "STALE (expired, operation never finished)"
    return "Claim    : %s - %s ran '%s' on %s (%s), since %s, expires %s" % (
        word, c["operator_declared"], c["action"], c.get("host", "?"), c["op_id"], c["created_utc"], c["expires_utc"])


CLAIM_RC = {"none": 0, "active": 10, "stale": 11, "malformed": 12}


def read_events(d):
    """-> (events sorted by time, list of malformed file names)"""
    evs, bad = [], []
    ed = events_dir(d)
    if os.path.isdir(ed):
        for name in sorted(os.listdir(ed)):
            if not name.endswith(".json"):
                continue
            try:
                with open(os.path.join(ed, name), encoding="utf-8") as f:
                    e = json.load(f)
                if not isinstance(e, dict) or parse_iso(e.get("ts_utc")) is None or not e.get("op_id"):
                    raise ValueError("missing ts_utc/op_id")
                e["_file"] = name
                evs.append(e)
            except (OSError, ValueError) as ex:
                bad.append("%s (%s)" % (name, ex))
    evs.sort(key=lambda e: (e["ts_utc"], e["_file"]))
    return evs, bad


def sessions(evs):
    """Pair successful start/stop results. Observed by our scripts - NOT a billing record."""
    out, open_s = [], None
    for e in evs:
        if e.get("kind") != "result" or e.get("outcome") != "success":
            continue
        if e["action"] == "start":
            if open_s:
                open_s["end"] = None
                open_s["note"] = "no stop recorded before the next start"
                out.append(open_s)
            open_s = {"start": e["ts_utc"], "end": None, "type": e.get("instance_type", "?"),
                      "started_by": e.get("operator_declared", "?"), "stopped_by": "-", "note": ""}
        elif e["action"] == "stop":
            if open_s:
                open_s["end"], open_s["stopped_by"] = e["ts_utc"], e.get("operator_declared", "?")
                out.append(open_s)
                open_s = None
            else:
                out.append({"start": None, "end": e["ts_utc"], "type": e.get("instance_type", "?"),
                            "started_by": "-", "stopped_by": e.get("operator_declared", "?"),
                            "note": "no tracked start (started outside these tools or record missing)"})
    if open_s:
        open_s["note"] = "still open: no stop recorded yet"
        out.append(open_s)
    return out


def unfinished_ops(evs, claim):
    done = {e["op_id"] for e in evs if e.get("kind") == "result"}
    live = claim["op_id"] if claim else None
    seen = {}
    for e in evs:
        if e.get("kind") == "intent" and e["op_id"] not in done and e["op_id"] != live:
            seen[e["op_id"]] = e
    return list(seen.values())


# ------------------------------------------------------------------ commands
def cmd_claim_acquire(a):
    os.makedirs(events_dir(a.dir), exist_ok=True)
    status, c = load_claim(a.dir)
    if status != "none":
        print(describe_claim(status, c))
        return CLAIM_RC[status]
    created = now()
    claim = {"schema": SCHEMA, "op_id": scrub(a.op_id), "action": a.action, "operator_declared": scrub(a.operator),
             "operator_verified": False, "host": scrub(a.host), "created_utc": iso(created),
             "expires_utc": iso(created + dt.timedelta(minutes=a.ttl_minutes))}
    claim.update({k: v for k, v in kv_fields(a.fields).items() if k in ("instance_id", "region")})
    try:
        fd = os.open(claim_path(a.dir), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        print("Another claim appeared while claiming.")
        return 10
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(claim, f, indent=2, sort_keys=True)
        f.write("\n")
    try:
        save_event(a.dir, base_event(a, "intent", kv_fields(a.fields)))
    except Exception as ex:  # do not leave a claim without its intent record
        os.remove(claim_path(a.dir))
        print("could not write intent event: %s" % ex)
        return 1
    print("claim acquired: %s" % a.op_id)
    return 0


def cmd_claim_show(a):
    status, c = load_claim(a.dir)
    print(describe_claim(status, c))
    return CLAIM_RC[status]


def cmd_claim_release(a):
    status, c = load_claim(a.dir)
    if status == "none":
        return 0
    if status == "malformed" or c["op_id"] != a.op_id:
        print("claim belongs to a different operation; leaving it in place")
        return 1
    os.remove(claim_path(a.dir))
    return 0


def cmd_claim_discard(a):
    """Remove OUR OWN claim and intent event after a failed publish (matched by op id)."""
    status, c = load_claim(a.dir)
    if status in ("active", "stale") and c["op_id"] == a.op_id:
        os.remove(claim_path(a.dir))
    ed = events_dir(a.dir)
    if os.path.isdir(ed):
        for name in os.listdir(ed):
            if "-%s-" % a.op_id in name:
                os.remove(os.path.join(ed, name))
    return 0


def cmd_claim_clear(a):
    status, c = load_claim(a.dir)
    if status == "none":
        print("No claim to clear.")
        return 0
    if status == "active":
        print(describe_claim(status, c))
        print("That claim is still within its time limit; it will not be cleared.")
        return 10
    note = "cleared stale claim" if status == "stale" else "cleared unreadable claim.json"
    if status == "stale":
        note += " %s (%s by %s)" % (c["op_id"], c["action"], c["operator_declared"])
    os.remove(claim_path(a.dir))
    ev = base_event(a, "claim_cleared", dict(kv_fields(a.fields), outcome="cleared", note=note))
    save_event(a.dir, ev)
    print(note)
    return 0


def cmd_event_add(a):
    print(save_event(a.dir, base_event(a, a.kind, kv_fields(a.fields))))
    return 0


def cmd_history(a):
    evs, bad = read_events(a.dir)
    status, claim = load_claim(a.dir)
    print("Ledger history (UTC). Durations are what our scripts OBSERVED - not an AWS bill.")
    print("Operators are SELF-DECLARED (shared AWS key), not verified identities.")
    print("events=%d unreadable=%d" % (len(evs), len(bad)))
    ss = sessions(evs)
    print("\nSessions")
    if not ss:
        print("  (none recorded)")
    for s in ss:
        dur = "-"
        if s["start"] and s["end"]:
            dur = human((parse_iso(s["end"]) - parse_iso(s["start"])).total_seconds())
        print("  %-20s -> %-20s  %-8s  %-14s start:%s stop:%s %s" % (
            s["start"] or "?", s["end"] or "?", dur, s["type"], s["started_by"], s["stopped_by"], s["note"]))
    print("\nOperations")
    shown = [e for e in evs if e.get("kind") != "intent"]
    if not shown:
        print("  (none recorded)")
    for e in shown[-a.limit:]:
        detail = e.get("requested_type") or e.get("note") or e.get("error", "")
        print("  %-20s %-10s %-8s %-12s %s %s" % (e["ts_utc"], e["action"], e.get("outcome", "-"),
                                               e.get("operator_declared", "?"), e["op_id"], detail))
    attention = [e for e in evs if e.get("kind") == "result" and e.get("outcome") in ("failed", "timeout")]
    attention_ops = unfinished_ops(evs, claim if status in ("active", "stale") else None)
    print("\nNeeds attention")
    if not (attention or attention_ops or bad or status in ("stale", "malformed")):
        print("  nothing")
    for e in attention:
        print("  %s %s %s by %s: %s" % (e["ts_utc"], e["action"], e["outcome"], e.get("operator_declared", "?"), e.get("error", "")))
    for e in attention_ops:
        print("  %s %s by %s (%s): started but no result recorded (interrupted?)" % (
            e["ts_utc"], e["action"], e.get("operator_declared", "?"), e["op_id"]))
    for b in bad:
        print("  unreadable event file: %s" % b)
    if status in ("stale", "malformed"):
        print("  " + describe_claim(status, claim))
    return 0


def cmd_last_start(a):
    evs, _ = read_events(a.dir)
    last = None
    for e in evs:
        if e.get("kind") == "result" and e["action"] in ("start", "stop") and e.get("outcome") == "success":
            last = e
    if last and last["action"] == "start":
        print("%s by %s (declared) as %s" % (last["ts_utc"], last.get("operator_declared", "?"), last.get("instance_type", "?")))
    else:
        print("none")
    return 0


def cmd_uptime(a):
    t = parse_iso(a.since)
    if t is None:
        print("unknown")
        return 1
    secs = (now() - t).total_seconds()
    print(human(max(secs, 0)))
    return 0


def cmd_diagnose(a):
    evs, bad = read_events(a.dir)
    status, claim = load_claim(a.dir)
    adv = []
    print(describe_claim(status, claim))
    if status == "active":
        adv.append("An operation is in progress. Wait for it; do not start another.")
    if status in ("stale", "malformed"):
        adv.append("Check the AWS state below, then run: make clear-claim   (asks for confirmation, never touches AWS)")
    for e in unfinished_ops(evs, claim if status in ("active", "stale") else None):
        print("Interrupted: %s %s by %s (%s) has no result recorded." % (e["ts_utc"], e["action"], e.get("operator_declared", "?"), e["op_id"]))
        adv.append("Compare the AWS state with what %s intended, then record nothing by hand; just use make status/start/stop as needed." % e["op_id"])
    for b in bad:
        print("Unreadable event file: %s" % b)
        adv.append("Open or delete the unreadable file(s) listed above after checking them in Git history.")
    last = None
    for e in evs:
        if e.get("kind") == "result" and e["action"] in ("start", "stop") and e.get("outcome") == "success":
            last = e
    expected = None if last is None else ("running" if last["action"] == "start" else "stopped")
    aws = a.aws_state
    print("AWS state: %s    Last recorded outcome: %s" % (aws, ("%s by %s at %s" % (last["action"], last.get("operator_declared", "?"), last["ts_utc"])) if last else "none"))
    if aws == "unknown":
        adv.append("AWS could not be read. Fix credentials/network (make validate) before relying on any record.")
    elif last is None and aws == "running":
        print("Mismatch: instance is running but no tracked start exists (started outside these tools, or the record is not synced).")
        adv.append("Run: make sync   (to fetch teammates' records). If still empty, the instance was started outside the tools; 'make stop' can still stop it and will record an untracked session.")
    elif expected and expected != aws and aws in ("running", "stopped"):
        print("Mismatch: records say '%s' but AWS says '%s'." % (expected, aws))
        adv.append("Someone changed the instance outside the tools, or a record was never pushed. Run: make sync, then make history.")
    else:
        print("Records and AWS state agree (or AWS is in a transitional state).")
    for x in adv:
        print("ADVICE: " + x)
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dir", required=True, help="ledger directory")
    sub = p.add_subparsers(dest="cmd", required=True)

    def add(name, fn, op=False, who=False, fields=False):
        sp = sub.add_parser(name)
        sp.set_defaults(fn=fn)
        if op:
            sp.add_argument("--op-id", required=True)
        if who:
            sp.add_argument("--operator", required=True)
            sp.add_argument("--host", required=True)
        if fields:
            sp.add_argument("fields", nargs="*")
        return sp

    s = add("claim-acquire", cmd_claim_acquire, True, True, True)
    s.add_argument("--action", required=True)
    s.add_argument("--ttl-minutes", type=int, required=True)
    add("claim-show", cmd_claim_show)
    add("claim-release", cmd_claim_release, True)
    add("claim-discard", cmd_claim_discard, True)
    s = add("claim-clear", cmd_claim_clear, True, True, True)
    s.add_argument("--action", default="clear-claim")
    s = add("event-add", cmd_event_add, True, True, True)
    s.add_argument("--action", required=True)
    s.add_argument("--kind", required=True)
    s = add("history", cmd_history)
    s.add_argument("--limit", type=int, default=20)
    add("last-start", cmd_last_start)
    s = add("uptime", cmd_uptime)
    s.add_argument("--since", required=True)
    s = add("diagnose", cmd_diagnose)
    s.add_argument("--aws-state", default="unknown")
    a = p.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
