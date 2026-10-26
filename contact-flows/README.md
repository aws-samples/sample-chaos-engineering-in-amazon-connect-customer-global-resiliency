# Contact Flow Reference Files

> **⚠️ These JSON files are GENERATED and are not deployed.** The authoritative flow content is
> the inline `Content` property in `cfn/main-template.yaml`. Regenerate with `make flows`;
> `make lint` fails if they have drifted.
>
> Generating them from the template keeps them from drifting from what is deployed.

Why there is one flow per experiment, what each fault does and what it proves is in
[README.md](../README.md#the-four-experiments). This file covers only what you need to know to
**edit** the flows safely.

## Files

| File | Role |
|------|------|
| `menu-flow.json` | Entry flow. Announces `$.AwsRegion`, then a DTMF menu that transfers to one experiment flow per digit. **The phone number points here.** |
| `exp1-lambda-flow.json` | `GetParticipantInput` collects the account number as DTMF, then a direct `InvokeLambdaFunction` to `ConnectChaos-AccountLookup`. |
| `exp2-dynamodb-flow.json` | Direct `InvokeLambdaFunction` to `ConnectChaos-CallLogger` — the audit write Exp 2 breaks by severing DynamoDB. |
| `exp3-latency-flow.json` | Lex block whose code hook Exp 3 delays ~31 s. |
| `exp4-queue-flow.json` | Failure path does `UpdateContactTargetQueue` → `TransferContactToQueue` into `ConnectChaos-Overflow`. |

## Updating flows

Edit the inline `Content` property in `cfn/main-template.yaml` — that is what CloudFormation
deploys — then run `make flows` to regenerate these copies. Do not edit the JSON directly;
`make lint` regenerates and compares, so it will fail.

## Four rules the generator enforces, each learned from a failed deploy

**1. `$.AwsRegion`, never a hardcoded Region.** The Lambda and Lex ARNs use the ACGR runtime
token:

```
arn:aws:lex:$.AwsRegion:ACCOUNT_ID:bot-alias/BOT_ID/BOT_ALIAS_ID
arn:aws:lambda:$.AwsRegion:ACCOUNT_ID:function:FUNCTION_NAME
```

ACGR replicates flow content **verbatim**, so a hardcoded Region makes the replica Region invoke
the *source's* dependencies — after traffic transition your "healthy" Region still depends on the one you
just declared unhealthy. The failure is invisible unless you deploy both Regions and check which
Region's Lambda logged the call. It is preserved verbatim by the generator because it is a Connect
**runtime** token, not a CloudFormation reference.

`$.AwsRegion` works for Lambda and Lex ARNs only —
[ACGR requirements](https://docs.aws.amazon.com/connect/latest/adminguide/connect-global-resiliency-requirements.html).
Connect-internal ARNs such as queues are remapped by ACGR itself and need no token.

> When `EnableLexGlobalResiliency=false` (`ap-northeast-1`→`ap-northeast-3`) the per-Region bot
> IDs differ, so `$.AwsRegion` alone is not enough: the flow would have to select the Lex alias
> by Region. This sample does not do that and does not support that pair — see the README.

**2. The Lex block needs a prompt.** `ConnectParticipantWithLexBot` must carry `Text` (or
`PromptId` / `SSML` / `Media` / `LexInitializationData`) as well as the alias ARN. The flows here
always set `Text`.

**3. Error types are per-action and not interchangeable.** Which error types an action may declare
differs per action, as set out in the
[flow-language reference](https://docs.aws.amazon.com/connect/latest/devguide/flow-language-actions.html):

| Action | Permitted |
|---|---|
| `Compare` | `NoMatchingCondition` only |
| `InvokeLambdaFunction` | `NoMatchingError` only; supports no conditions at all |
| `GetParticipantInput` with `StoreInput=True` | must **not** declare `NoMatchingCondition`, and *must* supply `InputValidation` |

**4. `StoreInput` changes which error types the flows declare.** The reference documents that
`NoMatchingCondition` applies only when `StoreInput` is `"False"`, and that `InputValidation` is
required if and only if `StoreInput` is `"True"`. This sample also does not declare
`InputTimeLimitExceeded` when `StoreInput` is `"True"`, because the
[Store customer input block](https://docs.aws.amazon.com/connect/latest/adminguide/store-customer-input.html)
routes a timeout down the Success branch with the stored value `Timeout`.

- `StoreInput: "True"` → no `InputTimeLimitExceeded`, no `NoMatchingCondition`, `InputValidation` present
- `StoreInput: "False"` → `NoMatchingCondition` declared

`scripts/extract-flows.py` asserts all of the above, so `make lint` catches a violation before a
deploy does.

## One thing that is easy to miss

**DTMF digits can drop immediately after a `TransferToFlow`.** AWS documents that input entered
before the next flow's prompt finishes may be truncated. Each experiment flow therefore opens with
the Region announcement and a prompt before collecting anything, so a caller naturally waits.
