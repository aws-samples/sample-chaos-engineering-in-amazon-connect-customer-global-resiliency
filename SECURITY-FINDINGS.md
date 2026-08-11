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
| [Suppressed — deliberate design decision](#suppressed--deliberate-design-decisions) | 13 | 35 |
| [No action — verified false positive](#no-action--verified-false-positives) | 6 | 11 |
| [OPEN — recommended, not yet done](#open--recommended-and-not-yet-done) | 2 | 6 |
| **Total** | **23** | **54** |

Severity as reported: 1 ERROR, 47 WARNING, 6 INFO.

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

## OPEN — recommended and not yet done

These are **not** suppressed. They are genuine gaps and they remain open.

### `CKV_AWS_116` — no Dead Letter Queue on the Lambdas (×3)

**The most important finding in this report, and it is a reliability gap rather than a security
one.**

`TrafficShiftHandler` is invoked by EventBridge when the composite alarm fires. There is no DLQ on
the rule target and no on-failure destination on the function. If that invocation kept failing,
the failover event would eventually be dropped **with nothing recording it** — a real regional
impairment would not fail over, and every alarm and dashboard would still look correct.

That is the same silent-failure class as `FIXES.md` Fix 21, which this project has already been
bitten by. Recommended: an SQS DLQ on the EventBridge rule target, plus an alarm on its depth.

### `CKV_AWS_165` — DynamoDB point-in-time recovery disabled (×3)

PITR gives continuous backups with restore to any second in the last 35 days. These tables hold
one seed customer record, a chaos flag and a call log, all recreated by `make post-deploy` in
seconds, so the data value is near zero. It is one property per table at negligible cost and
should simply be enabled.

---

## Production hardening

Complete these before deploying anywhere that matters. The first two change the network path the
experiments depend on, so **each requires a redeploy and a live test call** — a wrong prefix list
or too tight an IAM condition will cause the faults to silently stop arming, which looks exactly
like a working system.

| # | Change | Clears | Re-test required |
|:-:|---|---|---|
| 1 | Scope the FIS network policy to this stack's VPC and to FIS-managed NACLs | `W11`, `CKV_AWS_111` | Experiment 2, live call |
| 2 | Add explicit `SecurityGroupEgress` limited to the DynamoDB and S3 gateway-endpoint prefix lists | `F1000` | Experiments 1–3, live call each |
| 3 | Add the EventBridge DLQ and an alarm on its depth | `CKV_AWS_116` | Verify only |
| 4 | Enable DynamoDB PITR on all three tables | `CKV_AWS_165` | Verify only |
| 5 | Enable VPC flow logs | `W60` | Verify only |
| 6 | Add S3 access logging and versioning, and update cleanup to delete object versions | `W35`, `W51`, `CKV_AWS_18`, `CKV_AWS_21` | Verify + a cleanup dry run |
| 7 | Re-evaluate reserved concurrency against your real call volume | `W92`, `CKV_AWS_115` | Load test |

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

| Rule | Findings suppressed |
|---|:-:|
| `W28` | 11 |
| `W92` | 5 |
| `W11` | 4 |
| `W89` | 2 |
| `F1000`, `W35`, `W51`, `W60` | 1 each |
| `CKV_AWS_115`, `CKV_AWS_173` | 3 each |
| `CKV_AWS_18`, `CKV_AWS_21`, `CKV_AWS_111` | 1 each |

Expected remaining: **`CKV_AWS_116` ×3 and `CKV_AWS_165` ×3**, the two open items, plus the bandit
and semgrep informational findings, which have no suppression comments applied.
