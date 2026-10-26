#!/usr/bin/env python3
"""
Check that the documentation, the code and the template still agree with each other.

`make lint` runs this. Every check exists because the drift it catches actually happened:
a parameter table describing parameters that no longer exist, garbled identifiers left by a
bulk rename, anchors that pointed nowhere, a traffic generator that emitted metrics no alarm
watched, and prose naming resources the template does not create.

Checks
  1. README parameter table  <->  template Parameters (names, required, defaults)
  2. Internal markdown links and anchors resolve (README, RUNBOOK, contact-flows/README)
  3. No garbled or retired identifiers anywhere in the text files
  4. Every ConnectChaos-* resource name used in the docs exists in the template
  5. Every `make <target>` shown in the docs is a real Makefile target
  6. Every repository path named in backticks exists
  7. Every fenced bash block parses (bash -n)
  8. Each traffic-generator fault type trips exactly the alarm it claims to
  9. No paragraph line is directly followed by `---` (Markdown renders that as a heading)

Usage:  python3 scripts/check-docs.py
Needs:  PyYAML (installed with cfn-lint).
"""
import contextlib
import importlib
import io
import os
import pathlib
import re
import subprocess  # nosec B404 - used only to run `bash -n` on fixed temp files
import sys
import tempfile
import types

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
os.chdir(ROOT)

DOCS = ["README.md", "RUNBOOK.md", "contact-flows/README.md", "CONTRIBUTING.md"]
TEXT_SUFFIXES = (".md", ".py", ".yaml", ".yml", ".sh", ".json")
SKIP_DIRS = {".git", "__pycache__", "build", "SecurityFindings", "node_modules", "venv", ".venv"}

errors: list[str] = []


def fail(where: str, msg: str) -> None:
    errors.append(f"  {where}: {msg}")


# ── template ────────────────────────────────────────────────────────────────────────────────
class _Loader(yaml.SafeLoader):
    pass


def _intrinsic(loader, suffix, node):
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node)
    else:
        value = loader.construct_mapping(node)
    return {"!" + suffix: value}


_Loader.add_multi_constructor("!", _intrinsic)
TEMPLATE_TEXT = pathlib.Path("cfn/main-template.yaml").read_text(encoding="utf-8")
TEMPLATE = yaml.load(TEMPLATE_TEXT, Loader=_Loader)  # nosec B506 - safe subclass loader


def text_files():
    for dirpath, dirs, files in os.walk("."):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            if name.endswith(TEXT_SUFFIXES) or name == "Makefile":
                yield os.path.normpath(os.path.join(dirpath, name))


def git_ignored(paths):
    try:
        out = subprocess.run(  # nosec B603 B607 - fixed argv, no shell
            ["git", "check-ignore", "-z", "--stdin"], input="\0".join(paths) + "\0",
            capture_output=True, text=True, check=False).stdout.split("\0")
    except OSError:
        return set()
    return {os.path.normpath(p) for p in out if p}


FILES = list(text_files())
_ignored = git_ignored(FILES)
FILES = [f for f in FILES if f not in _ignored]


# ── 1. parameter table ──────────────────────────────────────────────────────────────────────
def check_parameter_table():
    params = TEMPLATE["Parameters"]
    readme = pathlib.Path("README.md").read_text(encoding="utf-8")
    section = readme.split("## Parameters", 1)[1].split("\n## ", 1)[0]
    rows = {}
    for line in section.splitlines():
        if line.startswith("| `"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            rows[cells[0].strip("`")] = (cells[1], cells[2].strip("` "))
    for name in sorted(set(params) - set(rows)):
        fail("README.md", f"parameter {name} is in the template but not in the Parameters table")
    for name in sorted(set(rows) - set(params)):
        fail("README.md", f"Parameters table lists {name}, which is not a template parameter")
    for name, spec in params.items():
        if name not in rows:
            continue
        required, shown = rows[name]
        has_default = "Default" in spec
        if (not has_default) != (required == "✓"):
            fail("README.md", f"{name}: 'Required' column disagrees with the template")
        if has_default and name != "FISExtensionLayerArn":
            if shown.replace("''", "") != str(spec["Default"]):
                fail("README.md", f"{name}: default {shown!r} != template {spec['Default']!r}")


# ── 2. links and anchors ────────────────────────────────────────────────────────────────────
def slug(heading: str, seen: dict) -> str:
    h = re.sub(r"[`*_]", "", heading.strip().lower())
    h = re.sub(r"[^\w\- ]", "", h, flags=re.UNICODE).replace(" ", "-")
    n = seen.get(h, 0)
    seen[h] = n + 1
    return h if n == 0 else f"{h}-{n}"


def check_links():
    anchors = {}
    for doc in DOCS:
        if not os.path.exists(doc):
            continue
        seen, found = {}, set()
        in_fence = False
        for line in pathlib.Path(doc).read_text(encoding="utf-8").splitlines():
            if line.lstrip().startswith("```"):
                in_fence = not in_fence
            m = None if in_fence else re.match(r"^#{1,6}\s+(.*)", line)
            if m:
                found.add(slug(m.group(1), seen))
        anchors[doc] = found
    for doc in anchors:
        text = pathlib.Path(doc).read_text(encoding="utf-8")
        for m in re.finditer(r"\]\(([^)]+)\)", text):
            target = m.group(1)
            if target.startswith(("http://", "https://", "mailto:")):
                continue
            path, _, frag = target.partition("#")
            dest = doc if not path else os.path.normpath(os.path.join(os.path.dirname(doc), path))
            line_no = text[:m.start()].count("\n") + 1
            if path and not os.path.exists(dest):
                fail(f"{doc}:{line_no}", f"link to missing file {path}")
            elif frag and dest in anchors and frag not in anchors[dest]:
                fail(f"{doc}:{line_no}", f"anchor #{frag} does not exist in {dest}")


# ── 3. banned / garbled strings ─────────────────────────────────────────────────────────────
BANNED = [
    (r"imreplica", "garbled 'impaired' (rename damage)"),
    (r"Traffic transition[A-Za-z]", "garbled identifier (rename damage)"),
    (r"[A-Za-z]Traffic transition", "garbled identifier (rename damage)"),
    (r"IsPrimaryRegion|PrimaryRegion|PairedRegion|PairedConnectInstanceId",
     "retired identifier; the template uses Source/Replica"),
    (r"\bFixes? \d+\b", "citation of a FIXES.md that is not published"),
    (r"wire-replica-flow", "script was removed; Tokyo/Osaka is not supported"),
    (r"ConnectChaos-(?:MainIVR|ChaosTest)", "flow that the template no longer creates"),
    (r"(?i)no (?:AWS )?API (?:exposes|returns)", "false: list-flow-associations returns the number -> flow link"),
    (r"(?i)claimed-only", "false: a number claimed to a TDG is accepted"),
]


def check_banned():
    for path in FILES:
        if path == os.path.normpath("scripts/check-docs.py"):
            continue
        for n, line in enumerate(pathlib.Path(path).read_text(encoding="utf-8", errors="ignore")
                                 .splitlines(), start=1):
            for pattern, why in BANNED:
                if re.search(pattern, line):
                    fail(f"{path}:{n}", f"{why}: {line.strip()[:70]}")


# ── 3b. a text line directly above `---` turns into a heading ────────────────────────────────
def check_setext():
    for doc in DOCS:
        if not os.path.exists(doc):
            continue
        in_fence = False
        prev = ""
        for n, line in enumerate(pathlib.Path(doc).read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("```"):
                in_fence = not in_fence
            elif not in_fence and re.fullmatch(r"(?:-{2,}|={2,})\s*", line) and prev.strip():
                fail(f"{doc}:{n}", f"'{line.strip()}' directly under text renders as a heading; "
                                   f"add a blank line above it: {prev.strip()[:60]}")
            prev = line


# ── 4. resource names used in the docs exist in the template ────────────────────────────────
NAME = re.compile(r"ConnectChaos-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*")
REGION_SUFFIX = re.compile(r"-(?:us|eu|ap)-[a-z]+-\d$")


def check_names():
    defined = set(NAME.findall(TEMPLATE_TEXT))
    for doc in DOCS:
        if not os.path.exists(doc):
            continue
        for n, line in enumerate(pathlib.Path(doc).read_text(encoding="utf-8").splitlines(), 1):
            for token in NAME.findall(line):
                token = REGION_SUFFIX.sub("", token)
                if token not in defined:
                    fail(f"{doc}:{n}", f"'{token}' is not defined in cfn/main-template.yaml")


# ── 5. make targets ─────────────────────────────────────────────────────────────────────────
def check_make_targets():
    makefile = pathlib.Path("Makefile").read_text(encoding="utf-8")
    targets = set(re.findall(r"^([a-zA-Z][\w-]*):", makefile, re.M))
    for doc in DOCS:
        if not os.path.exists(doc):
            continue
        for n, line in enumerate(pathlib.Path(doc).read_text(encoding="utf-8").splitlines(), 1):
            m = re.match(r"\s*(?:#\s*)?make\s+([a-z][\w-]*)\b", line)
            if m and m.group(1) not in targets:
                fail(f"{doc}:{n}", f"'make {m.group(1)}' is not a Makefile target")


# ── 6. repository paths named in backticks ──────────────────────────────────────────────────
def check_paths():
    pat = re.compile(r"`((?:scripts|lambda|cfn|contact-flows|docs)/[A-Za-z0-9_./*-]+)`")
    for doc in DOCS:
        if not os.path.exists(doc):
            continue
        for n, line in enumerate(pathlib.Path(doc).read_text(encoding="utf-8").splitlines(), 1):
            for m in pat.finditer(line):
                ref = m.group(1).rstrip(".")
                if "*" in ref:
                    continue
                if not os.path.exists(ref):
                    fail(f"{doc}:{n}", f"path {ref} does not exist")


# ── 7. shell blocks parse ───────────────────────────────────────────────────────────────────
def check_shell_blocks():
    for doc in DOCS:
        if not os.path.exists(doc):
            continue
        text = pathlib.Path(doc).read_text(encoding="utf-8")
        for m in re.finditer(r"```bash\n(.*?)```", text, re.S):
            line_no = text[:m.start()].count("\n") + 2
            with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as fh:
                fh.write(m.group(1))
                name = fh.name
            try:
                res = subprocess.run(["bash", "-n", name], capture_output=True,  # nosec B603 B607
                                     text=True, check=False)
            finally:
                os.unlink(name)
            if res.returncode != 0:
                fail(f"{doc}:{line_no}", "bash block does not parse: "
                     + res.stderr.strip().splitlines()[-1][:90])


# ── 8. generator fault types trip exactly their alarm ───────────────────────────────────────
def check_generator():
    alarms = {}
    for name, res in TEMPLATE["Resources"].items():
        if res["Type"] == "AWS::CloudWatch::Alarm":
            p = res["Properties"]
            dims = set()
            for d in p.get("Dimensions", []):
                v = d["Value"]
                v = {"ConnectInstanceId": "INSTANCE", "LexFulfillmentHandler": "LexFulfillmentHandler"
                     }.get(v["!Ref"], v["!Ref"]) if isinstance(v, dict) and "!Ref" in v else v
                dims.add((d["Name"], v))
            alarms[name] = (p["Namespace"], p["MetricName"], frozenset(dims))
    emitted = []

    class _CloudWatch:
        def put_metric_data(self, Namespace, MetricData):  # noqa: N803 (boto3 signature)
            for m in MetricData:
                emitted.append((Namespace, m["MetricName"],
                                frozenset((d["Name"], d["Value"]) for d in m["Dimensions"])))

    fake = types.ModuleType("boto3")
    fake.client = lambda *a, **k: _CloudWatch()
    real = sys.modules.get("boto3")
    sys.modules["boto3"] = fake
    os.environ.update({"CONNECT_INSTANCE_ID": "INSTANCE", "LEX_BOT_ID": "B", "LEX_BOT_ALIAS_ID": "A",
                       "LAMBDA_FUNCTION_NAME": "LexFulfillmentHandler",
                       "QUEUE_NAME": "ConnectChaos-Overflow"})
    sys.path.insert(0, "lambda")
    try:
        sys.modules.pop("traffic_generator", None)
        gen = importlib.import_module("traffic_generator")

        def tripped(**event):
            emitted.clear()
            with contextlib.redirect_stdout(io.StringIO()):  # the handler prints its summary
                gen.handler(event, None)
            seen = set(emitted)
            return {n for n, a in alarms.items() if a in seen}

        expect = {"lambda": "AlarmExp1Lambda", "dynamodb": "AlarmExp2DynamoDB",
                  "lex": "AlarmExp3Latency", "flow": "AlarmExp4Queue"}
        for fault, alarm in expect.items():
            got = tripped(mode="faulty", fault_type=fault, count=1)
            if got != {alarm}:
                fail("lambda/traffic_generator.py",
                     f"fault_type={fault} trips {sorted(got)}, expected only [{alarm}]")
        if tripped(mode="healthy", count=1):
            fail("lambda/traffic_generator.py", "healthy mode trips an alarm")
    finally:
        sys.path.remove("lambda")
        if real is not None:
            sys.modules["boto3"] = real
        else:
            sys.modules.pop("boto3", None)


def main() -> int:
    for check in (check_parameter_table, check_links, check_banned, check_setext, check_names,
                  check_make_targets, check_paths, check_shell_blocks, check_generator):
        check()
    if errors:
        print(f"Docs check: {len(errors)} problem(s)\n" + "\n".join(errors), file=sys.stderr)
        return 1
    print("Docs check: OK (parameters, links, headings, names, targets, paths, shell blocks, generator)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
