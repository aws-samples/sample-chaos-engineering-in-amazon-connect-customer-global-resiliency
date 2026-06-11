# Chaos Engineering for Amazon Connect — Overview

## What Is This?

This sample lets you **test what happens when things break** in your Amazon Connect contact center — and proves that your multi-region setup can automatically recover.

Think of it as a fire drill for your phone system. You intentionally break one piece at a time, watch the alarms go off, and verify that calls automatically route to the healthy backup region.

---

## Why Does This Matter?

Contact centers can't afford downtime. When a customer calls and something is broken — a database is unreachable, a bot isn't responding, or a backend service is down — the call fails. Customers hear silence or get disconnected.

With **Amazon Connect Global Resiliency (ACGR)**, you run your contact center in two AWS regions simultaneously. If one region has a problem, calls automatically route to the other region where everything still works.

**But how do you know this failover actually works before a real outage?** That's what this sample solves.

---

## How It Works — The Simple Version

```
1. You deploy the sample
2. You press a button to break something (on purpose)
3. An alarm fires because the system detected the failure
4. Calls automatically shift to the backup region
5. Customers never notice — they get served normally from the backup
6. You stop the test — everything recovers
```

---

## What Can You Break?

| Test | What Breaks | What a Customer Would Experience (Without Failover) |
|------|------------|-----------------------------------------------------|
| **Test 1** | The backend function stops working | "Sorry, we can't help you right now" |
| **Test 2** | The customer database becomes unreachable | "I can't look up your account" |
| **Test 3** | The IVR bot takes too long to respond | Long silence, then an error message |
| **Test 4** | The call routing logic fails | Call rings but no agent ever answers |

Each test targets a **different part** of the system and watches a **different health signal** — so you can pinpoint exactly which component failed.

---

## What Happens During a Test

```
Normal: All calls go to Region A (primary)

During test:
  → You break something in Region A
  → The system detects the problem (within 1-2 minutes)
  → An alarm fires
  → Traffic automatically shifts: all NEW calls go to Region B (backup)
  → Calls already connected in Region A stay in Region A (in-flight calls are not moved)
  → Region B has the same bot, same data, same call flows
  → Customers calling during/after the switch are served normally from Region B
  → The traffic shift takes effect within ~30-60 seconds of the API call

After test:
  → You stop the test
  → Region A recovers
  → You shift traffic back to Region A (manually or automatically)
```

---

## Technical Summary

### AWS Services Used

| Service | Role in This Sample |
|---------|---------------------|
| **Amazon Connect** | Contact center — handles inbound calls, runs contact flows |
| **Amazon Lex V2** | IVR bot — understands what the caller is asking |
| **AWS Lambda** | Backend logic — looks up customer data, processes requests |
| **Amazon DynamoDB** | Database — stores customer records (replicated across regions) |
| **AWS Fault Injection Service (FIS)** | Chaos tool — injects controlled failures into components |
| **Amazon CloudWatch** | Monitoring — alarms detect when something is broken |
| **Amazon EventBridge** | Event routing — triggers failover when alarms fire |
| **ACGR (Traffic Distribution Group)** | Failover — shifts call traffic between regions |

### Fault Injection — What Breaks, How, and What Detects It

| Test | Component Broken | How It's Broken | Health Signal (Metric) | Where Metric Lives |
|:---:|---|---|---|---|
| **1** | Lambda (backend function) | FIS prevents execution — function returns error | `Errors` | AWS/Lambda |
| **2** | DynamoDB (database) | FIS blocks network traffic to database endpoint | `ContactFlowErrors` | AWS/Connect |
| **3** | Lex (IVR bot fulfillment) | FIS adds 15-second delay — bot times out waiting | `RuntimeLambdaErrors` | AWS/Lex |
| **4** | Contact Flow (call routing) | Chaos flag in database causes intentional failure | `MissedCalls` | AWS/Connect |

### How Failover Is Triggered

| Step | What Happens |
|:---:|---|
| 1 | FIS breaks a component (or user sets chaos flag) |
| 2 | CloudWatch detects the failure via the component's metric |
| 3 | Alarm fires → Composite Alarm enters ALARM state |
| 4 | EventBridge catches the alarm event |
| 5 | EventBridge triggers a Lambda that calls the ACGR `UpdateTrafficDistribution` API |
| 6 | All new calls route to the healthy paired region |

---

## What Gets Set Up

When you deploy this sample, it creates:

- **A Lex bot** — handles the IVR conversation ("What's your account number?")
- **A backend function** — looks up customer data
- **A customer database** — stores account information (replicated to both regions)
- **Two call flows** — the normal IVR path and a test flow
- **Fault injection experiments** — pre-configured "break this" buttons
- **Health alarms** — watch for each type of failure
- **Automatic failover** — shifts calls to the backup region when alarms fire
- **A monitoring dashboard** — see all metrics in one place

Everything deploys to **both regions** so the backup is always ready.

---

## Prerequisites

- An Amazon Connect instance with Global Resiliency already enabled (two paired regions)
- A Traffic Distribution Group (controls which region receives calls)
- A VPC with subnets (for network-level testing)

---

## Who Is This For?

- **Contact center teams** who want to validate their DR (disaster recovery) setup
- **Solutions architects** designing resilient Connect architectures
- **Operations teams** who need confidence that failover works before an actual incident

---

## Key Takeaway

> You don't need to wait for a real outage to find out if your failover works.
> This sample lets you **prove** it works — safely, repeatedly, any time you want.
