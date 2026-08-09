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


def main():
    check = "--check" in sys.argv
    text = TPL.read_text(encoding="utf-8")
    stale = []
    for logical_id, filename in FLOWS.items():
        flow = extract(text, logical_id)
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
