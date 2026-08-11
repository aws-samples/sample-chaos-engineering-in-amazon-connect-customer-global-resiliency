#!/usr/bin/env python3
"""Fail the build if a real environment identifier or credential is committed.

This sample is published, so no deployment-specific value belongs in it. Every check
below is a *pattern*, never a denylist of known-bad strings -- a denylist would have to
contain the very values it is meant to keep out of the repository.

Run via `make lint`, or directly:

    python3 scripts/scan-secrets.py            # scan the working tree
    python3 scripts/scan-secrets.py --staged   # scan what is about to be committed

Exit codes: 0 clean, 1 findings, 2 usage error.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

# ── what must never be committed ────────────────────────────────────────────────
#
# Each entry: (label, compiled regex, remediation hint)
CHECKS: list[tuple[str, re.Pattern[str], str]] = [
    (
        "AWS access key id",
        re.compile(r"\b(?:AKIA|ASIA|AIDA|AROA|AGPA|AIPA|ANPA|ANVA|APKA)[0-9A-Z]{16}\b"),
        "Rotate the key immediately, then remove it from the file.",
    ),
    (
        "private key block",
        re.compile(r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"),
        "Rotate the key immediately, then remove it from the file.",
    ),
    (
        "AWS secret access key (assignment)",
        re.compile(
            r"(?i)aws_secret_access_key\s*[:=]\s*[\"']?[A-Za-z0-9/+=]{40}",
        ),
        "Rotate the key immediately, then remove it from the file.",
    ),
    (
        "hardcoded credential assignment",
        re.compile(
            r"(?i)\b(?:password|passwd|secret|api[_-]?key|access[_-]?token)\b"
            r"\s*[:=]\s*[\"'][^\"'\s${}<>]{8,}[\"']"
        ),
        "Read it from Secrets Manager, SSM, or an environment variable.",
    ),
    (
        "AWS account id (12 digits)",
        re.compile(r"(?<![\w.-])\d{12}(?![\w.-])"),
        "Use ${AWS::AccountId}, $ACCT, or ACCOUNT_ID.",
    ),
    (
        "phone number (E.164)",
        re.compile(r"(?<![\w.])\+\d{1,3}[\s-]?\d{6,13}(?![\w.])"),
        "Use $PHONE or <caller-ani>.",
    ),
    (
        "UUID (Connect instance / TDG / flow / queue / contact id)",
        re.compile(
            r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
            r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"
        ),
        "Use $INSTANCE_ID / $TDG_ID, or <contact-id>.",
    ),
    (
        "VPC / subnet / security-group / ENI id",
        re.compile(r"\b(?:vpc|subnet|sg|eni|acl|rtb|igw|nat|eipalloc)-[0-9a-f]{8,17}\b"),
        "Let the template create them, or pass them as parameters.",
    ),
    (
        "FIS experiment template id",
        re.compile(r"\bEXT[A-Za-z0-9]{10,}\b"),
        "Read it from the stack outputs at runtime (see RUNBOOK Step 0).",
    ),
    (
        "Lex bot / alias id",
        # Lex ids are exactly 10 uppercase alphanumeric characters. An earlier version of
        # this check also required a digit, which let a real all-letter alias id through --
        # so every 10-character token is now flagged and the handful of English words that
        # collide are allowlisted below. Fail-closed: a new real id can never slip past,
        # and a new English word costs one allowlist line.
        re.compile(r"(?<![\w-])[A-Z0-9]{10}(?![\w-])"),
        "Use $LEX_BOT_ID / $LEX_BOT_ALIAS_ID, or a placeholder such as EXAMPLEBOT.",
    ),
]

# ── narrow, justified exemptions ────────────────────────────────────────────────
#
# Values that are public and AWS-owned, so they are safe and often necessary to name.
ALLOWED_LITERALS: dict[str, str] = {
    # AWS-published FIS Lambda-extension layer accounts. Both the account and the layer
    # version differ per Region, which is exactly why the docs name them.
    # https://docs.aws.amazon.com/fis/latest/userguide/actions-lambda-extension-arns.html
    "211125607513": "AWS-owned public FIS extension layer account (us-east-1)",
    "975050054544": "AWS-owned public FIS extension layer account (us-west-2)",

    # Ten-character uppercase words that collide with the Lex bot/alias id shape. Add to
    # this list only if the value is genuinely not an identifier.
    "EXAMPLEBOT": "documentation placeholder for a Lex bot id",
    "EXAMPLEALS": "documentation placeholder for a Lex bot alias id",
    "CONDITIONS": "English word",
    "CONNECTION": "English word",
    "EXPERIMENT": "English word",
    "PARAMETERS": "English word",
    "PARTICULAR": "English word",
    "RESILIENCY": "English word",
    "WARRANTIES": "English word",
}

# Binary or generated files with nothing to review.
SKIP_SUFFIXES = (".png", ".jpg", ".jpeg", ".gif", ".pdf", ".zip", ".pyc", ".ico")
# SecurityFindings holds scanner exports. They are gitignored, so they can never be committed,
# and they legitimately quote resource names from a real deployment. Scanning them would block
# `make lint` on a file that is not part of the source tree.
SKIP_DIRS = {".git", "__pycache__", "build", "node_modules", ".venv", "venv", "SecurityFindings"}

# This file necessarily contains the patterns and the exemption list.
SELF = os.path.normpath("scripts/scan-secrets.py")


def is_allowed(line: str, match: str) -> bool:
    """True if this specific match is an approved public value."""
    if match in ALLOWED_LITERALS:
        return True
    # An inline waiver, for a case the patterns cannot know about. Keep these rare.
    return "scan-secrets: allow" in line


def iter_files(staged: bool) -> list[str]:
    if staged:
        out = subprocess.run(
            ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"],
            capture_output=True, text=True, check=True,
        ).stdout.split()
        return [f for f in out if os.path.isfile(f)]

    found: list[str] = []
    for root, dirs, files in os.walk("."):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            found.append(os.path.normpath(os.path.join(root, name)))
    return found


def scan(paths: list[str]) -> list[tuple[str, int, str, str, str]]:
    findings: list[tuple[str, int, str, str, str]] = []
    for path in sorted(paths):
        if path.endswith(SKIP_SUFFIXES) or path == SELF:
            continue
        try:
            with open(path, encoding="utf-8", errors="ignore") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        for lineno, line in enumerate(lines, start=1):
            for label, pattern, hint in CHECKS:
                for m in pattern.finditer(line):
                    if is_allowed(line, m.group(0)):
                        continue
                    findings.append((path, lineno, label, m.group(0), hint))
    return findings


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--staged", action="store_true",
                    help="scan staged changes instead of the working tree")
    args = ap.parse_args()

    paths = iter_files(args.staged)
    findings = scan(paths)

    if not findings:
        print(f"Secrets scan: OK ({len(paths)} files, {len(CHECKS)} checks)")
        return 0

    print(f"Secrets scan: {len(findings)} finding(s)\n", file=sys.stderr)
    for path, lineno, label, value, hint in findings:
        shown = value if len(value) <= 24 else value[:21] + "..."
        print(f"  {path}:{lineno}", file=sys.stderr)
        print(f"      {label}: {shown}", file=sys.stderr)
        print(f"      -> {hint}", file=sys.stderr)
    print(
        "\nThis sample is published. Replace the value with a variable or a placeholder.\n"
        "If a match is genuinely a public, non-sensitive value, add it to ALLOWED_LITERALS\n"
        "in scripts/scan-secrets.py with a justification, or append the comment\n"
        "'scan-secrets: allow' to that line.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
