# Security Findings — Disposition and Justifications

Static analysis of this repository (cfn_nag, checkov, bandit, semgrep) produced **54 findings**
across **23 distinct rules**. This file records the disposition of every one.

Nothing here is dismissed as noise. Each finding is either a deliberate design decision with a
reason, a verified false positive, or an open recommendation that is still outstanding.

> ### ⚠️ Deployment requirement
>
> **Deploy this sample into a dedicated non-production AWS account.**
>
> This is not boilerplate. The FIS execution role can create, modify, delete and re-associate
> network ACLs on **any VPC in the account it is deployed into**, not only the VPC this stack
> creates. A mis-targeted experiment can therefore sever connectivity for unrelated workloads in
> the same account. The blast radius is the account, so the account is the boundary you must set.
>
> For production use, complete [Production hardening](#production-hardening) first. AWS gives the
> same guidance for this fault type: its
> [disrupt-connectivity tutorial](https://docs.aws.amazon.com/fis/latest/userguide/fis-tutorial-disrupt-connectivity.html)
> uses a broad managed policy for simplicity and recommends granting only the minimum permissions
> necessary for production.

---

## Summary

| Disposition | Rules | Findings |
|---|:-:|:-:|
| [Resolved by removing the resource](#resolved-by-removal) | 2 | 2 |
| [Suppressed — deliberate design decision](#suppressed--deliberate-design-decisions) | 15 | 41 |
| [No action — verified false positive](#no-action--verified-false-positives) | 6 | 11 |
| **Total** | **23** | **54** |

Severity as reported: 1 ERROR, 47 WARNING, 6 INFO. **Zero findings are unaddressed.**

Six of the suppressed findings — `CKV_AWS_116` (Dead Letter Queue) and `CKV_AWS_165` (DynamoDB
point-in-time recovery) — are accepted **only because this is a demonstration sample**. They are
marked `REQUIRED for production` in both their suppression reasons and the
[hardening table](#production-hardening). They are not defects in a sample; they are gaps in
anything real.

Suppressions are recorded as `Metadata.cfn_nag.rules_to_suppress` and `Metadata.checkov.skip` on
the affected resource, so the reason sits next to the code and the scanner stops reporting it. A
note in this file alone would not do that — the scanners do not read Markdown.

**One ERROR-severity finding existed (`F1000`) and it is suppressed, not fixed.** The reasoning is
below; the actual fix is listed under production hardening.

---

## Resolved by removal

| Rule | Resource | What happened |
|---|---|---|
| `W47` | `AlarmNotificationTopic` | SNS topic should specify `KmsMasterKeyId` |
| `CKV_AWS_26` | `AlarmNotificationTopic` | Ensure all data stored in the SNS topic is encrypted |

The topic was wired to the composite alarm's `AlarmActions` and `OKActions`, but the template
created **no subscription**, so it published into the void on every experiment run. It was dead
weight generating two findings, so it was deleted rather than justified.

Failover never depended on it. That path is `CompositeAlarm` → EventBridge rule →
`TrafficShiftHandler`, which is untouched.

**If you add a topic back, do not encrypt it with `alias/aws/sns`.** CloudWatch cannot publish to
a topic encrypted with the AWS-managed key — the alarm history shows *"CloudWatch Alarms does not
have authorization to access the SNS topic encryption key"* — because that key policy does not
grant `kms:Decrypt` / `kms:GenerateDataKey` and cannot be edited. Use a customer-managed key with
an explicit `cloudwatch.amazonaws.com` statement
([AWS re:Post](https://repost.aws/knowledge-center/cloudwatch-configure-alarm-sns)). The naive fix
satisfies both scanners and silently breaks notification.

---

## Suppressed — deliberate design decisions

### `W28` — explicit resource names (×11: 7 IAM roles, 4 alarms)

*"Resource found with an explicit name, this disallows updates that require replacement."*

**The fixed names are a requirement, not an oversight.**

1. **ACGR mandates it.** A Lambda invoked by an ACGR-replicated contact flow must have the *same
   function name* in both Regions. ACGR replicates flow content verbatim, so the paired Region
   resolves the identical function name. Generated names would differ per Region and failover
   would invoke a function that does not exist.
2. **Every operational tool addresses them by name.** `make verify`, `make reset`, the runbook's
   `describe-alarms` calls and the FIS stop conditions all reference these roles and alarms by
   literal name. Generated names would break all of them.

The tradeoff cfn_nag warns about — replacement updates — is real and accepted: changing one of
these names requires a stack replacement. That is preferable to breaking failover.

### `W11` — IAM policy allows `*` resource (×4 roles)

Scoped as far as each API permits. Per-statement justification:

| Role | Action | Why `*` |
|---|---|---|
| `LexBotRole` | `polly:SynthesizeSpeech` | Does not support resource-level permissions |
| `FISExecutionRole` | `tag:GetResources` | Resource Groups Tagging API does not support resource-level permissions |
| `FISExecutionRole` | `ec2:*NetworkAcl*`, `ec2:Describe*` | **The one worth reducing.** See [Production hardening](#production-hardening) |
| `TrafficShiftRole` | `cloudwatch:DescribeAlarms` | Does not support resource-level permissions; read-only |
| `TrafficGeneratorRole` | `cloudwatch:PutMetricData` | Does not support resource-level permissions — **already constrained** by a `cloudwatch:namespace` condition limiting it to `AWS/Lambda`, `AWS/Connect`, `AWS/Lex` |

Four of the five are unavoidable. The fifth is the FIS network policy, and it is the highest-risk
item in this report.

### `W92` / `CKV_AWS_115` — no reserved concurrency (×5 / ×3)

**Left unset deliberately.** This is a synchronous voice IVR path: a caller is on the line waiting
for the Lambda to return. A concurrency cap does not queue work, it *throttles* — which would
drop live calls. Capacity is bounded by inbound telephony, which is a far lower ceiling than
Lambda's default concurrency.

Reserving concurrency would also subtract from the account's unreserved pool, affecting unrelated
functions.

### `W89` — Lambda not deployed inside a VPC (×2)

`TrafficShiftHandler` and `TrafficGeneratorFunction` call only Connect and CloudWatch APIs, which
are public AWS endpoints. Placing them in the VPC would require paid interface endpoints and
change nothing about their exposure.

The three functions that *do* touch DynamoDB and S3 — `LexFulfillmentHandler`,
`CallLoggerHandler`, `AccountLookupHandler` — **are** VPC-attached with free gateway endpoints and
no NAT.

### `F1000` — missing egress rule (ERROR, `ChaosLambdaSecurityGroup`)

*"Missing egress rule means all traffic is allowed outbound."*

**Accurate. CloudFormation applies a default allow-all egress rule.** Accepted for this sample for
one reason: **the egress has nowhere to go.** The subnets are private with no NAT gateway and no
internet gateway, so `0.0.0.0/0` has no route off the VPC. The DynamoDB and S3 gateway endpoints
are the only reachable destinations, and they are reached via route table entries, not the
security group.

So the effective egress is already restricted — by routing rather than by the security group.
cfn_nag cannot see routing, which is why it reports this.

**This is the one suppression that hides a real gap**, because defence in depth should not rely on
a single control. The explicit rule is listed under production hardening.

### `W35` / `CKV_AWS_18` — no S3 access logging, and `W51` — no bucket policy

`FISConfigBucket` holds only short-lived FIS fault configuration, written by FIS and read by the
Lambda extension. No customer data. It already has:

- `BucketEncryption` — AES256 at rest
- `PublicAccessBlockConfiguration` — all four blocks enabled
- IAM-restricted access — only the FIS and Lambda execution roles

`W51` is satisfied in substance: access *is* restricted, by IAM rather than by a bucket policy,
and public access is blocked at the bucket. Access logging would require a second bucket that
would itself be flagged for the same rule.

### `CKV_AWS_21` — S3 versioning disabled

**Omitted deliberately, because enabling it breaks documented cleanup.** With versioning on,
`aws s3 rm --recursive` leaves non-current versions and delete markers, and CloudFormation cannot
delete a bucket that still holds versions — so `make` cleanup would start failing with
`DELETE_FAILED`, the exact problem the README cleanup warning exists to prevent.

Enabling versioning means also rewriting the cleanup to delete all versions. Not worth it for a
bucket of transient fault-config objects.

### `CKV_AWS_173` — Lambda environment variables not encrypted with a CMK

Every environment variable across all five functions was enumerated. They contain table names,
Region names, ARNs, a traffic distribution group ARN, and numeric thresholds. **No credential, no
secret, no customer data.** A CMK would add key management and cost with nothing to protect.

### `W60` — VPC has no flow log

There is no NAT and no internet gateway, so there is no egress path to observe. Recommended for
production, where the VPC is likely to be shared.

---

## No action — verified false positives

Each of these was checked against the actual code rather than taken at face value.

### `string-concat-in-list` ×2 — `scripts/scan-secrets.py:48,66` (semgrep)

Flags implicitly concatenated strings inside a list, as a heuristic for a forgotten comma. These
are two intentional multi-line regexes. **Verified by importing the module and matching both
patterns against their targets** — the credential-assignment pattern and the UUID pattern both
compile and match correctly.

### `logging-error-without-handling` ×3 — `lex_fulfillment_handler.py:157,203`, `traffic_shift_handler.py:173` (semgrep)

`logger.error(...)` followed by `raise`. The rule suggests downgrading to warning since the
exception propagates and will be logged again.

Kept at `error` on purpose. These three log lines are the diagnostic trail for the DynamoDB
failure path — Experiment 2's entire signal — and for a failed traffic shift. Most of the findings
recorded in `FIXES.md` were diagnosed from exactly these messages. The explicit message is more
useful than a bare traceback.

### `B311` ×3 — `traffic_generator.py:67,97,123` (bandit)

*"Standard pseudo-random generators are not suitable for security purposes."* `random` is used to
jitter synthetic CloudWatch metric values. Nothing security-relevant.

### `B404` / `B603` / `B607` — `scripts/scan-secrets.py:21,134` (bandit)

`subprocess` use. The only call is `git diff --cached --name-only --diff-filter=ACMR`, passed as a
**fixed argument list with no shell and no untrusted input**. `B607` (partial executable path) is
accurate — `git` is resolved from `PATH` — and accepted for a developer-run lint script.

---

### `CKV_AWS_116` — no Dead Letter Queue (×3) — sample scope only

**Accepted for this sample. Required for production.**

Two invocation paths, and they differ:

- **Synchronous** — the three Lambdas the contact flows invoke. A DLQ has no meaning here: the
  caller is on the line experiencing the failure, and the flow's Error branch is the handling. A
  queued retry minutes later is worthless.
- **Asynchronous** — EventBridge → `TrafficShiftHandler`, and this is the one that matters. With
  no DLQ on the rule target and no on-failure destination, a repeatedly failing invoke would
  eventually drop the failover event **with nothing recording it.** A real impairment would not
  fail over, and every alarm and dashboard would still read correct. Same silent-failure class as
  `FIXES.md` Fix 21.

Tolerable here for one reason only: every experiment is **operator-initiated and verified against
the runbook**, so a lost event shows up immediately as "traffic did not shift" and is recovered by
re-running the experiment. That property does not exist in production, where the trigger is a real
outage and nobody is watching.

Production requires an SQS DLQ on the EventBridge rule target plus an alarm on its depth. See
[hardening item 3](#production-hardening).

### `CKV_AWS_165` — DynamoDB point-in-time recovery disabled (×3) — sample scope only

**Accepted for this sample. Required for production.**

PITR gives continuous backups with restore to any second in the last 35 days. These three tables
hold one seed customer record, a Region-scoped chaos flag and a call-audit log — demo fixtures,
recreated by `make post-deploy` in seconds. There is no production or customer data, so PITR would
protect nothing that is not trivially regenerated.

The moment this template carries real contact data, that reasoning stops applying. See
[hardening item 4](#production-hardening).

---

## Production disclaimer

**This repository is a demonstration sample. It has not been assessed for production use, and it
is not cleared for it.**

Every suppression in this template was justified **against the threat model of a sample running in
a dedicated non-production account**: short-lived demo data, no real customers, an operator present
for every experiment, and a bounded, self-reverting fault. Those assumptions are what make the
reasoning valid. None of them hold in production.

Specifically, the following are accepted here *because* it is a sample and must be revisited before
any production use:

| Accepted for the sample | Why it does not carry over |
|---|---|
| Account-wide FIS NACL permissions (`W11`, `CKV_AWS_111`) | A production account contains workloads a mis-targeted experiment must not be able to reach |
| Allow-all security-group egress (`F1000`) | Relies on there being no NAT and no internet gateway. Add one and the control disappears |
| No Dead Letter Queue (`CKV_AWS_116`) | Relies on an operator watching each run. In production the trigger is a real outage and nobody is watching |
| No DynamoDB PITR (`CKV_AWS_165`) | Relies on the data being regenerable demo fixtures |
| No reserved concurrency (`W92`, `CKV_AWS_115`) | Untested against real call volume |
| No flow logs, S3 access logging or versioning (`W60`, `W35`, `CKV_AWS_18`, `CKV_AWS_21`) | Forensics and auditability are not optional in production |

**Production use requires additional verification beyond this document:** completing the hardening
below, a security review against your own organisation's controls, and re-validating all four
experiments on live telephony after the changes — because two of the hardening items alter the
network path the faults depend on, and getting them wrong looks identical to a working system.

Chaos engineering against a production contact centre additionally needs blast-radius planning,
a rollback plan, and agreement from whoever owns the customer-facing service.

---

## Production hardening

Complete these before deploying anywhere that matters. Items 1 and 2 change the network path the
experiments depend on, so **each requires a redeploy and a live test call** — a wrong prefix list
or too tight an IAM condition will cause the faults to silently stop arming, which looks exactly
like a working system.

| # | Change | Priority | Clears | Re-test required |
|:-:|---|---|---|---|
| 1 | Scope the FIS network policy to this stack's VPC and to FIS-managed NACLs | **Highest** | `W11`, `CKV_AWS_111` | Experiment 2, live call |
| 2 | Add explicit `SecurityGroupEgress` limited to the DynamoDB and S3 gateway-endpoint prefix lists | High | `F1000` | Experiments 1–3, live call each |
| 3 | Add an SQS DLQ on the EventBridge rule target, plus an alarm on its depth | High | `CKV_AWS_116` | Verify only |
| 4 | Enable DynamoDB PITR on all three tables | Medium | `CKV_AWS_165` | Verify only |
| 5 | Enable VPC flow logs | Medium | `W60` | Verify only |
| 6 | Add S3 access logging and versioning, and update cleanup to delete object versions | Medium | `W35`, `W51`, `CKV_AWS_18`, `CKV_AWS_21` | Verify + a cleanup dry run |
| 7 | Re-evaluate reserved concurrency against real call volume | Low | `W92`, `CKV_AWS_115` | Load test |
| 8 | Encrypt Lambda environment variables with a CMK if you add any secret to them | Low | `CKV_AWS_173` | Verify only |

Items 3 and 4 are the cheapest: both are additive, neither changes an existing code path, and both
are verifiable without a phone call. If you only do two things from this table, do those.

### Plan for item 1 — scoping the FIS network policy

This is the highest-risk finding, so the plan is spelled out.

**What FIS actually does.** Per the
[FIS actions reference](https://docs.aws.amazon.com/fis/latest/userguide/fis-actions-reference.html),
`aws:network:disrupt-connectivity` clones the network ACL attached to the target subnet, adds deny
rules to the clone, tags it **`managedbyFIS=true`**, associates it with the subnet for the
duration, then deletes the clone and restores the original association.

Two consequences shape what is possible:

- The cloned NACL is created at run time, so **its ARN cannot be known in advance.** No
  `Resource` ARN can be written for `CreateNetworkAcl`. This is why the wildcard exists and why it
  cannot be removed outright.
- FIS **tags the clone**, which gives a condition key to constrain the destructive verbs against.

**Proposed split into three statements:**

1. **Read-only discovery** — `ec2:DescribeNetworkAcls`, `DescribeSubnets`, `DescribeVpcs`. Keep
   `Resource: '*'`; these do not support resource-level permissions and disclose only metadata.
2. **Creation, constrained by VPC** — `ec2:CreateNetworkAcl`, `ec2:CreateTags`. Keep
   `Resource: '*'` but add a condition restricting it to this stack's VPC, so the role cannot
   create an ACL anywhere else.
3. **Destructive verbs, constrained by the FIS tag** — `ec2:DeleteNetworkAcl`,
   `DeleteNetworkAclEntry`, `CreateNetworkAclEntry`, `ReplaceNetworkAclAssociation`, gated on the
   `managedbyFIS=true` tag that FIS itself applies, so the role can only modify or delete ACLs FIS
   created — never a pre-existing production ACL.

Statement 3 is the one that matters: it removes the ability to touch any NACL the role did not
create.

**Before implementing, two things must be verified rather than assumed:**

- The exact condition keys each `ec2` NACL action supports, against the *Actions, resources, and
  condition keys for Amazon EC2* IAM reference. Support is uneven across these actions, and a
  condition on an action that ignores it provides no protection while appearing to.
- Whether `ReplaceNetworkAclAssociation` evaluates the tag of the **new** ACL, the **old** one, or
  both. If it does not see the FIS tag, statement 3 must fall back to a VPC condition.

**Validation.** A too-tight condition makes FIS unable to create the clone and Experiment 2 stops
working. The only sufficient test is starting Experiment 2 and placing a real call, confirming the
caller hears *"We could not record your call"* and that
`ConnectChaos-Exp2-DynamoDB-<region>` reaches `ALARM`. `make verify` cannot detect this.

**Interim control, already in place:** every FIS experiment has a stop condition bound to its own
alarm and a bounded duration (`FISExperimentDuration`, default `PT5M`), so any disruption is
time-limited and self-reverting. The dedicated-account requirement above is the primary control
until item 1 lands.

---

## Reproducing the scan

Findings were produced by cfn_nag, checkov, bandit and semgrep. `make lint` runs cfn-lint plus
`scripts/scan-secrets.py`; the four scanners above run in the pipeline, not locally.

The suppression **syntax** was validated against AWS's own published templates and the template
parses cleanly with `cfn-lint`. The suppressions themselves were **not** confirmed against a live
cfn_nag or checkov run, because neither tool is installed in this workspace — the first pipeline
run after this change should confirm the counts drop as expected:

| Scanner | Rule | Findings suppressed |
|---|---|:-:|
| cfn_nag | `W28` | 11 |
| cfn_nag | `W92` | 5 |
| cfn_nag | `W11` | 4 |
| cfn_nag | `W89` | 2 |
| cfn_nag | `F1000`, `W35`, `W51`, `W60` | 1 each |
| checkov | `CKV_AWS_115`, `CKV_AWS_116`, `CKV_AWS_165`, `CKV_AWS_173` | 3 each |
| checkov | `CKV_AWS_18`, `CKV_AWS_21`, `CKV_AWS_111` | 1 each |
| | **Total** | **41** |

Plus 2 resolved by deleting the SNS topic = **43 of 54**.

Expected remaining after the next scan: the **11 bandit and semgrep informational findings**, which
carry no suppression comments. They are analysed under
[No action](#no-action--verified-false-positives) and left visible on purpose — each was verified
against the code, and an unsuppressed INFO is more honest than a `# nosec` that stops anyone
looking again.
