# Cost and Takeover Hardening — Design

- **Date:** 2026-11-11
- **Status:** Approved (2026-11-11)
- **Repos:** `aws-account-baseline` (most of it), `cv-site` (API catch-all route, pnpm cleanup)
- **Source:** the read-only security and cost-exposure audit of 2026-11-11. Owner rule: never a large bill,
  whatever the cause.

## 1. What the audit found

Anonymous traffic can't cost more than a few dollars before something stops it. The large-bill paths
all need a compromised credential or dependency, and the kill switch can't bound them because it only
stops CloudFront and Lambda. This design closes the ones that cost USD 0 to close.

| # | Finding | Fix in this design |
|---|---|---|
| H1 | The baseline's workflows, including the admin-equivalent `apply` job, use actions pinned by tag | §2 |
| H2 | No account-level S3 Block Public Access; the deploy role could open a `cv-site-*` bucket, and S3 egress is invisible to the kill switch | §3 |
| H3 | The deploy role can create many functions, APIs or distributions; enough of them make the kill switch time out and fail open | §4 |
| H4 | The `execute-api` endpoint: unmatched routes aren't counted or throttled per route, and a trip leaves it up | §5 |
| H5 | The estimate ignores the free tier, so about 41 GB of traffic takes the site offline while the real bill is USD 0 | §6 |
| H6 | Hygiene: no Dependabot on the baseline, stale pnpm exclusions, fork-PR approval only for first-time contributors | §7 |

Not in scope (owner decisions or his own accounts): GitHub Pro for cv-site branch protection (declined
for now), root MFA, GitHub 2FA and Actions budget, a custom SCP, Cloudflare and Pulumi account settings.
They are listed in cv-site `docs/PROGRESS.md` under "Waiting on Gonçalo".

## 2. H1: pin every action by commit SHA (baseline)

- Every `uses:` in `.github/workflows/*.yml` becomes `owner/repo@<40-char SHA> # vX.Y.Z`, as cv-site
  already does. The SHAs are resolved from the tags in use today (`gh api repos/<owner>/<repo>/git/ref/tags/<tag>`,
  dereferencing annotated tags).
- A `.github/dependabot.yml` for the `github-actions` ecosystem, weekly, with a 7-day cooldown, so pins
  move through reviewed PRs.
- Repo setting: Actions → "Require actions to be pinned to a full-length commit SHA" on. This is a
  settings change through the API; the owner approves it.

## 3. H2: account-level S3 Block Public Access (baseline)

- `aws_s3_account_public_access_block` with all four flags true. Nothing in the account serves S3
  publicly: the site bucket is private behind CloudFront OAC, which is not public access.
- `baseline-plan` gets `s3:GetAccountPublicAccessBlock`; `baseline-apply` gets that and
  `s3:PutAccountPublicAccessBlock` (both on `*`: the actions take no resource). The grants ship in a
  first PR, the resource in the next, because a role can't use permissions granted in the same apply.
- The cv-site roles have no account-level S3 action (their S3 grants are on `cv-site-*` ARNs), so they
  can't turn it off. A test pins that.

## 4. H3: inventory limits in the kill switch (baseline)

The switch already lists distributions, API Gateway v2 APIs (HTTP and WebSocket) and functions on every run. Before reading any
metric, a `check` compares those counts with limits:

| Resource | Limit (Terraform variable, default) | Today |
|---|---|---|
| CloudFront distributions | `kill_switch_max_distributions = 2` | 1 |
| API Gateway v2 APIs | `kill_switch_max_apis = 2` | 1 |
| Lambda functions other than the switch | `kill_switch_max_functions = 2` | 1 |

- The default is 2, one above today's inventory: Pulumi replaces some resources create-before-delete,
  and a limit of 1 would trip the switch (and take the site down) in the middle of a normal deploy.
  Anything beyond that headroom needs the variable raised first.
- Over a limit while armed: **trip**, with reason `inventory: <n> <kind> (limit <m>)`. No metric is read,
  so a flood of resources can't make the run time out first. The trip email reports the estimate as unknown.
- The limits reach the Lambda as environment variables. Adding a legitimate resource (staging, PR
  previews) means raising the variable in the baseline first; the README says so.
- The `>20 reads` cap stays as a second line.

## 5. H4: the execute-api endpoint

**cv-site (Pulumi):** add a `$default` route to the HTTP API, integrated with the contact Lambda. Every
request then matches a route, so the stage throttle (2/5) applies and the request is counted in the
`Count` metric the switch reads. The Lambda already answers anything but `POST /api/contact` with 404,
and its reserved concurrency (2) bounds the work.

**Baseline (kill switch):** on a trip, after the distributions and before the functions, set
`DisableExecuteApiEndpoint = true` on every API Gateway v2 API (HTTP or WebSocket) whose endpoint is enabled, recording the API ID
first; a rearm sets it back to false for the recorded ones. CloudFront reaches the API through that
endpoint, which doesn't matter while tripped: the distribution is off.

- State: a new key `disabled_apis` (list of API IDs). A stored document without the key is read as
  having an empty list, so the live parameter needs no migration; every write includes it.
- IAM: the Lambda's role gets `apigateway:PATCH` on `arn:aws:apigateway:<region>::/apis/*`.
- The summary gains `apis` (a count). The workflow prints it.
- Unknown, stated honestly: AWS doesn't document whether requests to a disabled endpoint, or throttled
  (429) requests, are billed. Disabling the endpoint is the strongest control available without WAF.

## 6. H5: count CloudFront's always-free allowance (baseline)

CloudFront's always-free tier is 1 TB of data transfer out and 10 million requests a month. The
estimate subtracts it before pricing:

- `billable_bytes = max(0, downloaded_bytes − 1e12) + uploaded_bytes` (the allowance is for data transfer
  out, so uploads are priced in full), `billable_requests = max(0, cloudfront_requests − 10_000_000)`.
- The allowances are Terraform variables (`kill_switch_free_cloudfront_bytes`,
  `kill_switch_free_cloudfront_requests`), so they can be lowered or set to 0. The free tier is shared
  across the AWS Organization; no other account uses CloudFront today.
- Effect: the fast trigger fires when the **real** CloudFront bill is about USD 5, not at 41 GB. An
  attacker can no longer take the CV offline for free; the worst case in money is unchanged (the trip
  point is the same real USD 5, and the budget still trips at USD 10 and 20).
- Prices stay deliberately high; API Gateway and Lambda free tiers stay ignored (small, and API
  Gateway's expires).

## 7. H6: hygiene

- Baseline: Dependabot security updates on (repo setting), plus the `dependabot.yml` of §2.
- Baseline and cv-site: fork pull request workflows require approval for **all outside collaborators**
  (repo setting).
- cv-site: remove the `minimumReleaseAgeExclude` entries from `pnpm-workspace.yaml` (their versions are
  older than 3 days now) and confirm `pnpm install --frozen-lockfile` passes.
- Not changed: the preview role's `lambda:Get*` (Pulumi's preview needs `GetFunction`, which returns the
  environment). Documented in the threat model as a residual risk: a PR job can read the recipient
  address.

## 8. Testing

- Python: table tests for the allowance (below, at and above 1 TB and 10M); flow tests for the
  inventory trip (no metric read happens), for the API disable on trip and restore on rearm (recorded
  before the change, never overwritten, skipped when already disabled), and for reading an old state
  without `disabled_apis`; a Stubber contract test for `update_api`.
- Terraform: exact-map tests for the new IAM statements and the account public access block; the new
  environment variables; mutation checks as usual.
- cv-site: a Pulumi mock test for the `$default` route and its integration; after deploy, a GET to an
  unmatched path on the public site still returns the site's own 404 (CloudFront only forwards `/api/*`).
- After the applies: `status` through the workflow (armed, `apis: 0`), and one more short drill, since
  the trip path changes: trip, check the API endpoint is disabled, rearm, check it's back and that the
  contact form's endpoint answers through CloudFront.

## 9. Rollout

1. Baseline PR A: SHA pins, Dependabot config, the IAM grants for §3 and §5 (plan/apply roles).
2. Baseline PR B: account public access block, kill switch changes (§4, §5, §6).
3. cv-site PR: `$default` route, pnpm cleanup, docs (threat model, PROGRESS).
4. Repo settings (§2, §7), with the owner's approval.
5. Short drill.

Cost of everything here: USD 0.
