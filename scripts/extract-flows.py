#!/usr/bin/env python3
"""
Generate contact-flows/*.json from the authoritative inline flow content in
cfn/main-template.yaml.

Why this exists: the reference copies previously drifted from the template until they
contradicted their own README - it described an InvokeLambdaFunction block the JSON did not
contain. Reference files that lie are worse than no reference files, and "remember to update
both" is not a control. Generating them makes drift structurally impossible, and `make lint`
re-runs this in --check mode so divergence fails the build instead of shipping.

CloudFormation !Sub placeholders are replaced with readable placeholders, since a standalone
JSON cannot resolve them.

Usage:
  python3 scripts/extract-flows.py            # write the files
  python3 scripts/extract-flows.py --check    # fail if the files are stale
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TPL = ROOT / "cfn/main-template.yaml"
OUT = ROOT / "contact-flows"

# Logical id in the template -> generated file name.
FLOWS = {
    "MenuFlow": "menu-flow.json",
    "Exp1Flow": "exp1-lambda-flow.json",
    "Exp2Flow": "exp2-dynamodb-flow.json",
    "Exp3Flow": "exp3-latency-flow.json",
    "Exp4Flow": "exp4-queue-flow.json",
}

# CloudFormation intrinsics -> placeholders a reader can substitute by hand.
# $.AwsRegion is deliberately NOT substituted: it is a Connect runtime token, not a
# CloudFormation ref, and preserving it is the whole point of Fixes 8 and 16.
SUBS = [
    (r"\$\{AWS::AccountId\}", "ACCOUNT_ID"),
    (r"\$\{ConnectChaosBot\.Id\}", "BOT_ID"),
    (r"\$\{ConnectChaosBotAlias\.BotAliasId\}", "BOT_ALIAS_ID"),
    (r"\$\{CallLoggerHandler\}", "ConnectChaos-CallLogger"),
    (r"\$\{AccountLookupHandler\}", "ConnectChaos-AccountLookup"),
    (r"\$\{Exp1Flow\}", "EXP1_FLOW_ID"),
    (r"\$\{Exp2Flow\}", "EXP2_FLOW_ID"),
    (r"\$\{Exp3Flow\}", "EXP3_FLOW_ID"),
    (r"\$\{Exp4Flow\}", "EXP4_FLOW_ID"),
    (r"\$\{ChaosOverflowQueue\.QueueArn\}", "OVERFLOW_QUEUE_ARN"),
]


def extract(text, logical_id):
    """Pull the single-line JSON body of `Content: !Sub |` for one flow resource."""
    m = re.search(
        rf"^  {logical_id}:\n(?:.*\n)*?      Content: !Sub \|\n((?:        .*\n)+)",
        text,
        re.M,
    )
    if not m:
        raise SystemExit(f"ERROR: could not locate Content for {logical_id} in {TPL}")
    body = "".join(line[8:] for line in m.group(1).splitlines(keepends=True))
    for pattern, replacement in SUBS:
        body = re.sub(pattern, replacement, body)
    leftover = re.findall(r"\$\{[^}]+\}", body)
    if leftover:
        raise SystemExit(
            f"ERROR: {logical_id} still contains unsubstituted CloudFormation refs: "
            f"{sorted(set(leftover))}. Add them to SUBS in {__file__}."
        )
    return json.loads(body)


# Error types Amazon Connect accepts per action. Declaring a disallowed type fails
# CreateContactFlow with a bare InvalidContactFlowException - no field, no reason - so these
# are validated here instead of being discovered by a failed stack update.
#
# The last two entries were established by creating throwaway flows against the real API,
# because the flow-language reference does not state either of them:
#   StoreInput=True  -> InputTimeLimitExceeded is REJECTED (a timeout takes the Success
#                       branch with the stored value set to the literal string "Timeout"),
#                       and InputValidation is REQUIRED.
#   StoreInput=False -> NoMatchingCondition is REQUIRED, since conditions are supported.
ALLOWED_ERRORS = {
    "MessageParticipant": {"NoMatchingError"},
    "InvokeLambdaFunction": {"NoMatchingError"},
    "Compare": {"NoMatchingCondition"},
    "TransferToFlow": {"NoMatchingError"},
    "UpdateContactTargetQueue": {"NoMatchingError"},
    "TransferContactToQueue": {"NoMatchingError", "QueueAtCapacity"},
    "ConnectParticipantWithLexBot": {"NoMatchingError", "NoMatchingCondition"},
    "GetParticipantInput": {"NoMatchingError", "NoMatchingCondition",
                            "InputTimeLimitExceeded", "InvalidPhoneNumber"},
    "DisconnectParticipant": set(),
}


def validate(name, flow):
    """Reject flows Amazon Connect would refuse, and ACGR-unsafe region pinning."""
    problems = []
    ids = [a["Identifier"] for a in flow["Actions"]]
    if len(ids) != len(set(ids)):
        problems.append("duplicate action identifiers")
    if flow["StartAction"] not in ids:
        problems.append(f"StartAction {flow['StartAction']!r} is not an action")

    for a in flow["Actions"]:
        t, ident = a["Type"], a["Identifier"]
        if t not in ALLOWED_ERRORS:
            problems.append(f"{ident}: unmodelled action type {t}")
            continue
        errs = {e["ErrorType"] for e in a["Transitions"].get("Errors", [])}
        for bad in sorted(errs - ALLOWED_ERRORS[t]):
            problems.append(f"{ident}: {t} may not declare {bad}")
        if t == "InvokeLambdaFunction" and "Conditions" in a["Transitions"]:
            problems.append(f"{ident}: InvokeLambdaFunction does not support Conditions")
        if t == "GetParticipantInput":
            stored = a["Parameters"].get("StoreInput")
            if stored not in ("True", "False"):
                problems.append(f"{ident}: StoreInput must be exactly 'True' or 'False', "
                                f"got {stored!r} (the value is case-sensitive)")
            if stored == "True":
                if "InputTimeLimitExceeded" in errs:
                    problems.append(f"{ident}: StoreInput=True must NOT declare "
                                    "InputTimeLimitExceeded - a timeout takes the Success "
                                    "branch with the value 'Timeout'")
                if "InputValidation" not in a["Parameters"]:
                    problems.append(f"{ident}: StoreInput=True requires InputValidation")
            if stored == "False" and "NoMatchingCondition" not in errs:
                problems.append(f"{ident}: StoreInput=False requires a NoMatchingCondition "
                                "error branch")
        for tgt in (([a["Transitions"]["NextAction"]] if "NextAction" in a["Transitions"] else [])
                    + [c["NextAction"] for c in a["Transitions"].get("Conditions", [])]
                    + [e["NextAction"] for e in a["Transitions"].get("Errors", [])]):
            if tgt not in ids:
                problems.append(f"{ident}: transition to unknown action {tgt!r}")

    body = json.dumps(flow)
    for service in ("lambda", "lex"):
        if f"arn:aws:{service}:" in body and f"arn:aws:{service}:$.AwsRegion:" not in body:
            problems.append(f"a {service} ARN is pinned to one Region - the paired Region "
                            "would use the wrong one")
    if "Connected in region $.AwsRegion" not in body:
        problems.append("does not announce the serving Region")

    if problems:
        raise SystemExit(f"ERROR: {name} would be rejected or is ACGR-unsafe:\n  - "
                         + "\n  - ".join(problems))


def main():
    check = "--check" in sys.argv
    text = TPL.read_text(encoding="utf-8")
    stale = []
    for logical_id, filename in FLOWS.items():
        flow = extract(text, logical_id)
        validate(logical_id, flow)
        rendered = json.dumps(flow, indent=2) + "\n"
        path = OUT / filename
        if check:
            current = path.read_text(encoding="utf-8") if path.exists() else ""
            if current != rendered:
                stale.append(filename)
            continue
        path.write_text(rendered, encoding="utf-8")
        types = sorted({a["Type"] for a in flow["Actions"]})
        print(f"  wrote {filename}  ({len(flow['Actions'])} actions: {', '.join(types)})")

    if check:
        if stale:
            raise SystemExit(
                "ERROR: these reference flows are stale against cfn/main-template.yaml: "
                f"{stale}\n       Run: python3 scripts/extract-flows.py"
            )
        print("Flows: OK (reference copies match the template)")


if __name__ == "__main__":
    main()
