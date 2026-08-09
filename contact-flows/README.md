# Contact Flow Reference Files

> **⚠️ These JSON files are GENERATED and are not deployed.** The authoritative flow content is
> the inline `Content` property in `cfn/main-template.yaml`. Regenerate with `make flows`;
> `make lint` fails if they have drifted.
>
> They used to be hand-maintained copies, and drifted until they contradicted this README —
> it described an `InvokeLambdaFunction` block the JSON did not contain. Generating them makes
> that class of error impossible rather than relying on discipline.

## ACGR: use `$.AwsRegion`, never a hardcoded Region

The Lex alias ARN uses the ACGR runtime token `$.AwsRegion` in place of the Region:

```
arn:aws:lex:$.AwsRegion:ACCOUNT_ID:bot-alias/BOT_ID/BOT_ALIAS_ID
```

ACGR replicates flow content **verbatim** to the paired region. A hardcoded Region makes the
paired region invoke the *primary* region's Lex bot — so after failover your "healthy" region
still depends on the one you just declared unhealthy. The failure is invisible unless you
deploy both regions and check which region's Lambda logged the call.

At flow runtime Connect resolves `$.AwsRegion` to the Region the flow is executing in. This
works because Lex Global Resiliency preserves the bot ID and alias ID across Regions, so the
same ID pair is valid in both.

`$.AwsRegion` is supported **only** for Lambda and Lex ARNs — see
[ACGR requirements](https://docs.aws.amazon.com/connect/latest/adminguide/connect-global-resiliency-requirements.html)
and `FIXES.md` Fix 8.

> When `EnableLexGlobalResiliency=false` (`ap-northeast-1`↔`ap-northeast-3`) the per-Region
> bot IDs differ, so `$.AwsRegion` alone is not enough — run `scripts/wire-paired-flow.sh`
> after deployment.

## Two things the deployed flows do that these copies illustrate

**The Lex block needs a prompt.** `ConnectParticipantWithLexBot` must carry `Text` (or
`PromptId`/`SSML`/`Media`/`LexInitializationData`) as well as the alias ARN, or the flow fails
to create with `InvalidContactFlowException` (`FIXES.md` Fix 2).

**Experiment 2 depends on a direct Lambda invoke.** The Main IVR flow invokes
`ConnectChaos-CallLogger` via `InvokeLambdaFunction` before the Lex block — a genuine audit
write. When Experiment 2 severs DynamoDB, that invoke fails and the flow takes its **Error**
branch, which is what makes `ContactFlowErrors` fire on its own path instead of only riding
the Lambda-Errors alarm (`FIXES.md` Fix 6).

**Experiment 4 depends on the failure path transferring to a no-agent queue.** The chaos-test
flow's error path does `UpdateContactTargetQueue` → `TransferContactToQueue` into
`ConnectChaos-Overflow`, a queue referenced by no routing profile. Contacts wait there
indefinitely, driving `LongestQueueWaitTime` (`FIXES.md` Fix 9).

## Files

| File | Description |
|------|-------------|
| `main-ivr-flow.json` | Main IVR — greeting, call-logger invoke, Lex bot, success/error paths |
| `chaos-test-flow.json` | Chaos test — failure path transfers to the no-agent overflow queue |

## Updating flows

Edit the inline `Content` property in `cfn/main-template.yaml` — that is what CloudFormation
deploys — then run `make flows` to regenerate these copies. Do not edit the JSON directly;
`make lint` will fail because it regenerates them and compares.

`$.AwsRegion` is preserved verbatim by the generator. It is a Connect **runtime** token, not a
CloudFormation reference, and it must survive into the deployed flow for the paired region to
work at all — see `FIXES.md` Fix 8 (Lex ARN) and Fix 16 (Lambda ARN).
