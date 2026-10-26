#!/usr/bin/env python3
"""Send TwinLab operational emails through Gmail SMTP using only the stdlib."""
import argparse
import datetime as dt
from email.message import EmailMessage
import re
import smtplib
import ssl
import sys

EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")


def addresses(value):
    out = []
    for item in value.split(","):
        item = item.strip()
        if item and item not in out:
            if not EMAIL_RE.fullmatch(item):
                raise ValueError("invalid email address in recipient settings")
            out.append(item)
    return out


def build_message(a):
    mode = a.preview_kind if a.mode == "preview" else a.mode
    sender = a.from_address.strip()
    if not EMAIL_RE.fullmatch(sender):
        raise ValueError("invalid Gmail sender address")
    recipients = addresses(a.to)
    operator_email = a.operator_email.strip()
    if not EMAIL_RE.fullmatch(operator_email):
        raise ValueError("invalid operator email address")
    if mode in ("event", "test") and operator_email not in recipients:
        recipients.append(operator_email)
    if mode == "reminder":
        recipients = [operator_email]
    if not recipients:
        raise ValueError("no notification recipients configured")

    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    if mode == "reminder":
        duration = (
            "%s minutes" % a.duration_minutes
            if a.duration_minutes < 60
            else "%s hours" % (a.duration_minutes // 60)
        )
        subject = "TwinLab instance has been running for %s" % duration
        lead = "Your TwinLab instance has been running for at least %s." % duration
    elif mode == "test":
        subject = "TwinLab email notification test"
        lead = "This is a test message. No AWS operation was performed."
    else:
        subject = "TwinLab instance %s" % ("STARTED" if a.action == "start" else "STOPPED")
        lead = "The TwinLab EC2 instance was %s successfully." % ("started" if a.action == "start" else "stopped")
    lines = [
        lead,
        "",
        "Operator (self-declared): %s" % a.operator,
        "Instance: %s" % a.instance_id,
        "Region: %s" % a.region,
        "Instance type: %s" % a.instance_type,
        "Observed state: %s" % a.state,
        "Public IP: %s" % (a.public_ip or "unavailable"),
        "Operation ID: %s" % a.op_id,
        "Notification time (UTC): %s" % now.isoformat().replace("+00:00", "Z"),
    ]
    if mode == "reminder":
        lines.extend(["", "If you are finished, coordinate with your teammates before stopping the shared instance."])

    msg = EmailMessage()
    msg["From"] = sender
    msg["To"] = ", ".join(recipients)
    msg["Subject"] = subject
    msg.set_content("\n".join(lines) + "\n")
    return msg, recipients


def send(a):
    msg, recipients = build_message(a)
    if a.mode == "preview":
        print("PREVIEW: Gmail email not sent.")
        print(msg)
        return 0

    try:
        with open(a.password_file, "r", encoding="utf-8") as f:
            password = f.read().strip().replace(" ", "")
    except OSError:
        print("Gmail App Password file could not be read.", file=sys.stderr)
        return 1
    if not password:
        print("Gmail App Password file is empty.", file=sys.stderr)
        return 1

    try:
        with smtplib.SMTP("smtp.gmail.com", 587, timeout=20) as smtp:
            smtp.ehlo()
            smtp.starttls(context=ssl.create_default_context())
            smtp.ehlo()
            smtp.login(a.from_address, password)
            smtp.send_message(msg, from_addr=a.from_address, to_addrs=recipients)
    except (OSError, smtplib.SMTPException) as exc:
        detail = str(exc).replace(password, "[REDACTED]").replace("\r", " ").replace("\n", " ")
        print("Gmail delivery failed (%s): %s" % (type(exc).__name__, detail[:300]), file=sys.stderr)
        return 1
    print("Gmail notification sent to %s recipient(s)." % len(recipients))
    return 0


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("mode", choices=("event", "reminder", "test", "preview"))
    p.add_argument("--preview-kind", choices=("event", "reminder", "test"), default="test")
    p.add_argument("--action", choices=("start", "stop"), required=True)
    p.add_argument("--from-address", required=True)
    p.add_argument("--to", default="")
    p.add_argument("--operator-email", required=True)
    p.add_argument("--operator", required=True)
    p.add_argument("--op-id", required=True)
    p.add_argument("--instance-id", required=True)
    p.add_argument("--region", required=True)
    p.add_argument("--instance-type", required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--public-ip", default="")
    p.add_argument("--duration-minutes", type=int, default=240)
    p.add_argument("--password-file", required=True)
    return p


def main():
    args = parser().parse_args()
    if args.duration_minutes < 1 or args.duration_minutes > 4320:
        print("duration-minutes must be 1..4320", file=sys.stderr)
        return 2
    try:
        return send(args)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
