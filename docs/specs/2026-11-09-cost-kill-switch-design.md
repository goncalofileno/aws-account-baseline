# Cost Kill Switch — Design

- **Date:** 2026-11-09
- **Status:** Approved (brainstorming)
- **Repos:** `aws-account-baseline` (the kill switch, its roles and its workflow); `cv-site` (a deploy gate and docs)
- **Owner rule:** "Spending must stay visible, and a large bill must never happen, whatever the cause."
  The owner accepts about **USD 10 a month** as the worst normal month before the site takes itself offline.

## 1. Problem

The account's existing cost guardrails only report: a USD 5 monthly budget (email) and Cost Anomaly
Detection (daily email at USD 1 or more). Billing data lags 8 to 24 hours, so neither of them can
stop a flood before it costs money.

CloudFront stays on pay-as-you-go pricing, which has no hard cap. The flat-rate plans can't be used
because they block the custom response headers policy that carries the site's CSP. A 1 Gbps flood
moves about 450 GB an hour.

A CloudWatch alarm on the CloudFront metrics isn't possible either. Those metrics exist only in
`us-east-1`, and the account's AWS-managed region SCP denies CloudWatch writes (`PutMetricAlarm`),
SNS and EventBridge there. Reads are allowed: `cloudwatch:GetMetricStatistics` in `us-east-1` was
tested on 2026-11-09 and returns 1-minute CloudFront data with about 4 minutes of lag.

## 2. Goals and non-goals

### Goals

- Take the site offline **automatically** when estimated spend crosses a low threshold, within minutes.
- Catch any other cause of spend, more slowly, through the actual bill.
- Bring the site back **only** after an explicit action by the owner, which can be done from a phone.
- Keep the guard outside the site's own deploy role, so `cv-site-deploy` can't disarm it.
- Cost about USD 0, inside the free tiers.

### Non-goals

- **AWS WAF / rate limiting.** It costs at least USD 6 a month, more than half the cap, and doesn't
  cap the bill.
- **Cloudflare proxy in front of CloudFront.** It is a useful extra layer, but a client can still
  reach `*.cloudfront.net` directly. It goes in the cv-site backlog.
- **A maintenance page while the site is off.** With the distribution disabled, visitors get a
  CloudFront error. A page would need the Cloudflare proxy.
- **Automatic re-enable.**

## 3. Cost sources and coverage

| Source | Bounded today? | Covered by |
|---|---|---|
| CloudFront data transfer and requests | No | Fast trigger (§5.1) |
| API Gateway, contact Lambda, their logs (also reachable through `execute-api` directly) | Throttle 2/5 and reserved concurrency 2: worst case about USD 8–10 a month | Fast trigger (§5.1) covers the contact Lambda and API Gateway requests, but **not** CloudWatch Logs ingestion; only the budget (slow trigger, §5.2) covers that |
| SES | Turnstile before every send, SES daily quota | Slow trigger (§5.2) only: the fast trigger doesn't see SES |
| S3 | Read only by CloudFront through OAC | Fast trigger, through CloudFront |
| Leaked credentials or unexpected services | No IAM users, scoped OIDC roles, region SCP | Slow trigger (§5.2) |
| Cloudflare (free plan), GitHub Actions, Pulumi Cloud | No usage-based charges | Not applicable |

## 4. Architecture

Everything is in the baseline repo (Terraform), in `eu-north-1`, except the CloudFront metrics it
reads in `us-east-1`. No name starts with `cv-site-`. The cv-site roles are scoped to that prefix,
so they can't change any part of the guard. The IAM roles are named `baseline-*`: `baseline-apply`
already manages that prefix, and `cv-site-deploy` is denied `iam:*` on it.

```
EventBridge Scheduler (rate 1 min) ──{"action":"check"}──▶ ┐
Budget monthly-cost ACTUAL >200% / >400% ─▶ SNS cost-kill-switch-trigger ─▶ │ Lambda cost-kill-switch
GitHub workflow "kill-switch" (trip/rearm/status) ─▶ OIDC role baseline-kill-switch-operator ─▶ ┘
        │  reads: CloudWatch metrics (us-east-1, eu-north-1), CloudFront, Lambda, API Gateway
        │  state: SSM /cost-kill-switch/state
        └─▶ SNS cost-kill-switch-alerts ─▶ email (var.alert_email)
CloudWatch alarms (eu-north-1) on the Lambda: errors, heartbeat ─▶ SNS cost-kill-switch-alerts
```

| Resource | Notes |
|---|---|
| `aws_lambda_function.cost_kill_switch` | Python 3.13, boto3 from the runtime, no dependencies. Code in `functions/cost_kill_switch/`, zipped with `archive_file` (adds the `hashicorp/archive` provider). Memory 128 MB, timeout 60 s, reserved concurrency 1. Env: `STATE_PARAMETER`, `ALERTS_TOPIC_ARN`, `TRIGGER_TOPIC_ARN`, `THRESHOLD_USD=5` |
| Log group `/aws/lambda/cost-kill-switch` | 30-day retention. One JSON line per run (estimate and decision): about 4 MB a month |
| IAM role `baseline-cost-kill-switch` | See §7 |
| `aws_scheduler_schedule` `cost-kill-switch-check` | `rate(1 minute)`, input `{"action":"check"}`, no retries (the next minute is the retry), flexible window off, its own role `baseline-kill-switch-scheduler` allowed only `lambda:InvokeFunction` on the function |
| SNS `cost-kill-switch-trigger` | Topic policy lets `budgets.amazonaws.com` publish, conditioned on `aws:SourceAccount` and `aws:SourceArn` (`arn:aws:budgets::<account>:*`). Lambda subscription. Unencrypted (see §9) |
| SNS `cost-kill-switch-alerts` | Email subscription to `var.alert_email` (confirmed once by the owner). Only the Lambda and CloudWatch can publish |
| SSM parameter `/cost-kill-switch/state` | `String`, created as the armed state. `lifecycle { ignore_changes = [value] }`, since the Lambda owns the value |
| Budget `monthly-cost` | Two new notifications: ACTUAL > 200% (USD 10) and ACTUAL > 400% (USD 20), SNS subscriber `cost-kill-switch-trigger` |
| Alarm `cost-kill-switch-errors` | `AWS/Lambda` `Errors` Sum ≥ 1, period 60 s, 5 of 5 datapoints, missing data not breaching. Alarm and OK actions → alerts topic |
| Alarm `cost-kill-switch-heartbeat` | `AWS/Lambda` `Invocations` Sum < 1, period 600 s, 1 of 1, missing data **breaching**. Alarm and OK actions → alerts topic |
| OIDC role `baseline-kill-switch-operator` | Through `modules/github-oidc-role`, subject `environment:kill-switch` of this repo. Only `lambda:InvokeFunction` on the function |
| Workflow `.github/workflows/kill-switch.yml` | `workflow_dispatch`, inputs `action` (`status`, `trip`, `rearm`) and `reason` (required for `trip` and `rearm`). Job environment `kill-switch` (required reviewer: owner). Role ARN from secret `AWS_ROLE_KILL_SWITCH`. Fails when the invocation returns a `FunctionError`. Prints only the status, the reason and counts, never IDs |

## 5. Behaviour

### 5.1 Fast trigger: estimated spend

On every `check`, the Lambda estimates this month's spend from 00:00 UTC on the 1st until now. It
reads `GetMetricStatistics` with a period of 3600 s and the statistic `Sum`, which is at most 744
datapoints per call.

| Service (discovered each run) | Metrics | Price used (USD) |
|---|---|---|
| CloudFront: every distribution from `ListDistributions` (`us-east-1`, dims `DistributionId` and `Region=Global`) | `BytesDownloaded` + `BytesUploaded` | 0.12 per GB (10^9 bytes) |
| | `Requests` | 0.025 per 10,000 |
| API Gateway: every HTTP API from `GetApis` (dim `ApiId`) | `Count` | 1.20 per million |
| Lambda: every function from `ListFunctions` except `cost-kill-switch` (dim `FunctionName`) | `Invocations` | 0.20 per million |
| | `Duration` (ms) × `MemorySize` | 0.0000167 per GB-second |

The prices are deliberately above the real ones (the top of the common edge regions), and **free
tiers are ignored**, so the estimate overstates spend. They are constants in one module, commented
with the date they were checked.

- **A normal month** (about 2,000 requests and 17 MB a day) estimates at about USD 0.20.
- **Trip rule:** `estimate − acknowledged ≥ THRESHOLD_USD` (5). That is roughly 40 GB or 2 million
  CloudFront requests.
- **`acknowledged`** is 0 at the start of a month. It is set to the current estimate on every
  rearm, so each rearm grants another USD 5 of headroom for the rest of the month.
- **Month rollover:** when the state's `month` differs from the current UTC month, `check` resets
  `acknowledged` to 0 and stores the new month. A tripped state stays tripped.
- **Read cost:** about 6 metric reads per run, around 260,000 a month, inside the 1 million free
  `GetMetricStatistics` requests. The function logs a warning when one run needs more than 20 reads,
  because at 1 run a minute that would leave the free tier. After it has decided and saved, a run
  that made more than 20 reads raises, so the errors alarm emails.
- **Tripped checks read no metrics:** a `check` on a tripped state goes straight to enforcement
  (the estimate is reported as unknown). Only `status` and `rearm` read metrics while tripped, and
  they raise when the read fails.

**Reaction time:** about 4 min metric lag + up to 1 min to the next run + 5–15 min for the disabled
distribution to propagate, so about 10–20 min in total. A flood of up to 1 Gbps moves under 100 GB
in that time, inside the 1 TB CloudFront free tier, so it costs USD 0 in real money. Only a
sustained flood of tens of Gbps would cost more than USD 10 before the stop. AWS Shield Standard,
included with CloudFront, filters network-layer floods, and AWS may credit DDoS-related charges on
request. That limit is accepted: removing it would need WAF.

### 5.2 Slow trigger: the actual bill

The budget publishes to the trigger topic at USD 10 and again at USD 20. Each threshold fires once a
month. Any SNS record whose `TopicArn` equals `TRIGGER_TOPIC_ARN` trips the switch with reason
`budget`, whatever the estimate. Records from any other topic are logged and ignored.

### 5.3 Trip

1. Write the state first: `status=tripped`, `reason`, `tripped_at`, `estimate_usd`, with the lists
   below still empty.
2. For every enabled distribution: add its ID to `disabled_distributions` and save, then
   `GetDistributionConfig`, set `Enabled=false`, `UpdateDistribution` with `IfMatch`.
3. For every Lambda function except itself: read `GetFunctionConcurrency`, store the previous value
   in `concurrency` (`null` when none was set) and save, then `PutFunctionConcurrency` 0. That stops
   the contact Lambda, but API Gateway still accepts and bills requests at the stage throttle (2 rps,
   about 5 million a month, about USD 6, failing with 5xx). That is bounded and inside the accepted
   USD 10.
4. Then read the estimate (best effort, for a manual or budget trip; a threshold trip already has
   it), use it only in the alert email and the returned summary (the stored `estimate_usd` stays as written at trip time, `null` for these trips, so no write that could fail or overwrite the records sits between enforcement and the alert), and publish the alert, even if a step above failed
   (that failure is re-raised afterwards), so the one transition email is never lost and neither an
   SNS failure nor a metric read ever delays the stop.

Each entry is recorded before its resource changes, so a crash never leaves a change without a
record. Already-recorded entries are never overwritten: the original value is the one to restore.

**While tripped**, every `check` repeats steps 2–3, even when the metrics can't be read (the
estimate is then reported as unknown). It disables anything that came back, for example a new
distribution or a deploy that slipped through, and records it. The alert email goes out only
on the transition `armed → tripped`. A trip while already tripped is a no-op apart from enforcement.

### 5.4 Rearm

`{"action":"rearm","reason":"…"}`:

1. Re-enable every distribution in `disabled_distributions`.
2. Restore each function's recorded concurrency: `PutFunctionConcurrency` with the old value, or
   `DeleteFunctionConcurrency` when it was `null`.
3. Set `acknowledged` to the current estimate and `status=armed`. Clear the lists and save.
4. Publish an alert with the reason and the counts.

Rearm while armed is a no-op that returns the status. Resources the switch didn't change are left
alone, so Pulumi state matches AWS again and a `pulumi preview` shows no diff.

The other actions:
- `{"action":"trip","reason":"…"}` trips by hand (for a drill or an emergency).
- `{"action":"status"}` returns the state without the IDs and with the current estimate.
- Unknown actions raise an error.

### 5.5 State document

```json
{
  "status": "armed",
  "month": "2026-11",
  "acknowledged_usd": 0.0,
  "tripped_at": null,
  "reason": null,
  "estimate_usd": null,
  "disabled_distributions": [],
  "concurrency": {}
}
```

The format is validated on read. A malformed or missing parameter makes the run fail: it raises, so
the errors alarm fires. It is never treated as armed.

## 6. Failure handling

- **Fail open on reads, loudly.** If metrics or listings can't be read while armed, a `check` raises
  and doesn't trip (`status` and `rearm` raise too). A manual or budget trip, and enforcement while
  tripped, never depend on the metrics. The errors alarm emails after 5 failing minutes. Tripping blind would take the site down on
  an AWS hiccup.
- **Actions retry by repetition.** A failed `UpdateDistribution` (an ETag race, for example) or a
  failed concurrency change is retried on the next `check`, because the state is already `tripped`.
- **Errors leave the function sanitised.** A synchronous caller (the workflow) only ever sees
  `kill switch failed: <AWS error code or exception class>`; the full error, which can quote ARNs,
  stays in the function's logs.
- **Short client timeouts** (connect 5 s, read 10 s, standard retries) keep one hung call from
  using up the 60 s timeout.
- **Heartbeat.** If the schedule stops or the function is broken, the heartbeat alarm emails within
  10 minutes.
- **The alarms are in `eu-north-1`.** The SCP denies CloudWatch writes only in `us-east-1`. There
  are 2 alarms against the 10 free ones (the account has none today).

## 7. IAM

**Role `baseline-cost-kill-switch`** (the Lambda):

| Statement | Actions | Resource |
|---|---|---|
| Metrics | `cloudwatch:GetMetricStatistics` | `*` (no resource type) |
| CloudFront | `cloudfront:ListDistributions`, `GetDistributionConfig`, `UpdateDistribution` | `*` / `arn:aws:cloudfront::<account>:distribution/*` |
| API Gateway | `apigateway:GET` | `arn:aws:apigateway:eu-north-1::/apis` |
| Lambda list | `lambda:ListFunctions` | `*` |
| Lambda concurrency | `lambda:GetFunctionConcurrency`, `PutFunctionConcurrency`, `DeleteFunctionConcurrency` | `arn:aws:lambda:eu-north-1:<account>:function:*` |
| Not itself | **Deny** `lambda:PutFunctionConcurrency`, `DeleteFunctionConcurrency` | its own ARN |
| State | `ssm:GetParameter`, `ssm:PutParameter` | the state parameter |
| Alerts | `sns:Publish` | the alerts topic |
| Logs | `logs:CreateLogStream`, `logs:PutLogEvents` | its log group |

**Changes to the cv-site roles:**
- `cv-site-deploy` gets `ssm:GetParameter` on `/cost-kill-switch/state`, for the deploy gate.
- `cv-site-preview` gets nothing, because PR previews don't change anything.

**Cleanup in the same work, in a separate PR:**
- Drop the unused grants for CloudWatch alarms (`SiteAlarms`, `AlarmRead`) and AWS User
  Notifications (`SiteAlertNotifications`, `AlertNotificationsRead`). Keep
  `organizations:DescribeOrganization`.
- Fix the README, the baseline spec and the `roles-cv-site.tf` comment, which say CloudWatch is
  allowed in `us-east-1`. Only its reads are.

## 8. cv-site changes

- **`deploy.yml`:** a step "Cost kill switch gate" right after "Configure AWS credentials", for every
  trigger, scheduled runs included.
  - It reads the parameter. If `status` isn't `armed`, it fails with
    `::error::Cost kill switch is tripped (<reason>, <tripped_at>); rearm it before deploying`.
  - A missing parameter fails closed.
  - It prints only the status, reason and time.
  - The daily scheduled failure doubles as a reminder that the site is off. It also stops a
    `pulumi up` from re-enabling the distribution under the switch.
- **Docs:**
  - the `infra/README.md` "Cost guardrails" section;
  - the threat model (cost abuse row and the CloudFront bullet);
  - `docs/PROGRESS.md`;
  - a backlog item for the Cloudflare proxy.

## 9. Testing and checks

- **Python (`functions/cost_kill_switch/tests/`, pytest, no network, no new runtime dependencies):**
  - **Pure modules, table-driven:** `pricing` (the estimate from metric sums, the trip rule at the
    boundary), `state` (month rollover, the schema validation) and `events` (which records are
    ignored, tripped or rearmed).
  - **The flow (`handler.KillSwitch.run`) against in-memory fakes of the boto3 clients:** a trip
    disables enabled distributions only and records them; concurrency is recorded once and never
    overwritten; while tripped, enforcement catches a re-enabled distribution without reading
    metrics; a rearm restores exactly the recorded values (`Delete…` for `null`); the email is sent
    only on a transition; an SNS record from another topic is ignored; it never touches its own
    concurrency.
  - **Contract tests:** the boto3 call shapes are checked with botocore `Stubber` against the
    service models.
- **Terraform (`tests/cost_kill_switch.tftest.hcl`):**
  - the IAM statements, as exact maps, in the existing style;
  - the topic policy conditions;
  - the schedule input and rate;
  - the alarm settings, including `treat_missing_data`;
  - the budget notifications pointing at the trigger topic;
  - the initial value of the state parameter (`terraform test` can't see `lifecycle`, so
    `ignore_changes` on its value is checked in review);
  - the operator role's subject.
- **checkov:** inline skips with reasons:
  - SNS without a customer KMS key: Budgets can't publish to a topic encrypted with the AWS-managed
    key, and a customer key costs USD 1 a month;
  - Lambda without a VPC, DLQ or code signing;
  - the log group without KMS.
- **CI:** a `pytest` job in `ci.yml` (Python 3.13, `pytest` pinned in `functions/cost_kill_switch/requirements-dev.txt`).
- **Drill after go-live.** The owner picks a quiet hour; the site is off for about 20–30 min.
  1. Workflow `trip` (reason `drill`). Check: the alert email arrives, the site stops answering
     (CloudFront error), the contact Lambda's concurrency is 0, and a cv-site deploy fails at the gate.
  2. Workflow `rearm`. Check: the site answers 200, the contact Lambda's reserved concurrency is back
     to 2, `pulumi preview` shows no diff, and the deploy passes the gate.

## 10. Cost

| Item | Monthly use | Cost |
|---|---|---|
| Scheduler | about 43,200 invocations | free (14 million free) |
| Lambda | about 43,200 runs × ~1 s × 128 MB | free (1 million requests and 400,000 GB-s free) |
| `GetMetricStatistics` | about 260,000 | free (1 million free) |
| SNS | a few messages and emails | free |
| CloudWatch alarms | 2 | free (10 free) |
| Logs | about 4 MB | free (5 GB free) |
| SSM parameter (Standard) | 1 | free |
| Budget notifications to SNS (no budget action) | 2 | free |

## 11. Rollout

0. **Baseline PR "kill switch permissions":** `baseline-plan`/`baseline-apply` grants for the new
   resources and the `cv-site-deploy` read of the state. A role can't use permissions granted in the
   same apply, so this goes first.
1. **Baseline PR "cost kill switch":** apply; the owner confirms the alerts email subscription and
   creates the `kill-switch` environment (required reviewer: owner) and the secret
   `AWS_ROLE_KILL_SWITCH`; run the workflow with `status`.
2. **cv-site PR:** the deploy gate and the docs; merge; the deploy passes the gate.
3. **Drill** (§9), at a time agreed with the owner.
4. **Baseline cleanup PR** (§7).

## 12. Public repo note

The code and thresholds are public. That doesn't help an attacker: the only thing they learn is to
stay under about USD 5 a month, which is the goal. No account IDs, emails or distribution IDs are
committed or printed by the workflow.
