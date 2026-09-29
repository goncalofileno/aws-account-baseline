# AWS Account Baseline — Design

- **Date:** 2026-09-24
- **Status:** Approved (brainstorming)
- **Repo:** `aws-account-baseline` (new, public). This spec lives in `cv-site` until that repo exists, then moves there.
- **Build order:** sub-project **0** — must be applied before `cv-site` (sub-project 1) can deploy.

## 1. Purpose

A small, production-quality Terraform repository that prepares Gonçalo's personal AWS account for
the `cv-site` project and demonstrates Terraform proficiency (the site itself uses Pulumi).

It mirrors a common industry split: a platform team owns the account "landing zone" in Terraform;
product teams deploy on top with Pulumi/CDK.

### Goals

- GitHub Actions can deploy to AWS with **no long-lived AWS credentials** (OIDC only).
- Every role follows **least privilege**; the site's deploy role cannot escalate its own privileges.
- Cost is **capped and alerted**; account activity is **audited**.
- Code quality is visible: linting, security scanning, automated tests, reviewed applies.
- Code is compatible with both **Terraform and OpenTofu**, proven in CI.

### Non-goals

- AWS Organizations, multi-account landing zone, SCPs, Control Tower (the account already has these,
  created and managed by AWS as part of the "advanced AWS features" activation; this repo neither
  creates nor manages them).
- IAM user / IAM Identity Center setup (there is none; day-to-day human access is the browser-based
  `aws login` session described in §8).
- Anything specific to the site's runtime resources (those belong to `cv-site`/Pulumi).

## 2. Key decisions

| Decision | Choice | Why |
|---|---|---|
| IaC tool | Terraform (HCL), CI-tested with OpenTofu | Terraform is the name the market asks for; OpenTofu matrix proves portability |
| Minimum version | Terraform ≥ 1.10 / OpenTofu ≥ 1.10 | Needed for S3 native state locking |
| State | S3 backend, `use_lockfile = true`, no DynamoDB | Native locking, one fewer resource |
| State bucket bootstrap | Separate `bootstrap/` root, applied once with local state | Solves the chicken-and-egg problem |
| Region | `eu-north-1` (Stockholm) | Fixed by the account's AWS-managed SCP, which restricts the project's home region to `eu-north-1`/`us-east-1`/`us-west-2`; CloudFront serves users from edge locations regardless of origin region, so this has no latency impact |
| Apply in CI | Only on `main`, behind a GitHub Environment with required reviewer | IAM changes must be human-approved |

## 3. Repository structure

```
aws-account-baseline/
├─ bootstrap/                 # applied once, local state: creates the state bucket
│  └─ main.tf · variables.tf · outputs.tf · versions.tf · tests/
├─ modules/
│  ├─ github-oidc-role/       # reusable: IAM role assumable from a GitHub repo/ref via OIDC
│  └─ secure-bucket/          # reusable: private, encrypted, versioned, TLS-only S3 bucket
├─ main.tf                    # providers, backend, module wiring
├─ oidc.tf                    # GitHub OIDC provider
├─ roles-cv-site.tf           # cv-site-deploy, cv-site-preview, cv-site-boundary
├─ roles-baseline.tf          # baseline-plan, baseline-apply
├─ budget.tf
├─ cloudtrail.tf
├─ variables.tf · outputs.tf · versions.tf
├─ tests/                     # terraform test files (*.tftest.hcl) using mock providers
├─ Makefile                   # fmt / validate / lint / security / test / check (TF=tofu supported)
├─ .tflint.hcl · .checkov.yaml
├─ .github/workflows/ci.yml · apply.yml
└─ README.md                  # what it is, architecture, manual steps, how to run
```

## 4. Resources

### 4.1 Bootstrap (`bootstrap/`)

- S3 bucket `gf-tfstate-<account-id>` (via `modules/secure-bucket`): versioning on, SSE-S3 encryption, all public access blocked,
  bucket policy denying non-TLS requests, lifecycle expiring noncurrent versions after 90 days.
- Output: bucket name, used in the root module's backend config.

### 4.2 GitHub OIDC provider

- `aws_iam_openid_connect_provider` for `https://token.actions.githubusercontent.com`,
  audience `sts.amazonaws.com`.

### 4.3 Module `github-oidc-role`

Inputs: `name`, `github_owner`, `github_owner_id`, `github_repo`, `github_repo_id`, `subject_claims` (list, e.g. `ref:refs/heads/main`,
`pull_request`, `environment:production`), `policy_json`, optional `permissions_boundary_arn`,
`max_session_duration` (default 3600).

Trust policy conditions: `aud = sts.amazonaws.com` and `sub` matches
`repo:<owner>@<owner_id>/<repo>@<repo_id>:<claim>` (GitHub immutable subject) for each allowed claim (exact `StringEquals`/`StringLike` on the
full subject, never a bare wildcard on the repo).

### 4.4 Roles for `cv-site`

| Role | Assumable from | Purpose |
|---|---|---|
| `cv-site-deploy` | `repo:<owner>@<owner_id>/cv-site@<repo_id>:ref:refs/heads/main` | `pulumi up`, `s3 sync`, CloudFront invalidation |
| `cv-site-preview` | `repo:<owner>@<owner_id>/cv-site@<repo_id>:pull_request` | `pulumi preview` (read-only) |

**`cv-site-deploy` policy** (scoped to the `cv-site-` prefix wherever the service supports resource-level permissions):

- S3: full management of `arn:aws:s3:::cv-site-*` and its objects.
- CloudFront: create/update/delete distributions, functions, OAC, response headers and cache
  policies, `CreateInvalidation`. (CloudFront create actions do not support resource-level
  scoping; this is documented in a policy comment.)
- ACM (`us-east-1`): request/describe/delete certificates.
- Lambda: manage `function:cv-site-*`.
- API Gateway v2: manage APIs in `eu-north-1` (limited resource-level support; documented).
- CloudWatch Logs: manage `log-group:/aws/lambda/cv-site-*`.
- SSM: manage `parameter/cv-site/*`.
- SES: manage identities and send-related configuration.
- IAM: `CreateRole`/`PutRolePolicy`/`AttachRolePolicy`/`DeleteRole…` on `role/cv-site-*` **only if**
  `iam:PermissionsBoundary` equals the `cv-site-boundary` ARN; `iam:PassRole` on `role/cv-site-*`
  to `lambda.amazonaws.com` only.
- Deny: modifying or deleting `cv-site-boundary`, and any IAM action on the `baseline-*` roles.

**`cv-site-boundary`** (permissions boundary for every role the site creates, i.e. the Lambda
execution role): allows only CloudWatch Logs on `/aws/lambda/cv-site-*`, `ssm:GetParameter` on
`parameter/cv-site/*`, `kms:Decrypt` via SSM with the AWS-managed key, and `ses:SendEmail`/`SendRawEmail`.

**`cv-site-preview` policy:** `Get*`/`List*`/`Describe*` on the same services and resources as
the deploy role; no write actions.

### 4.5 Roles for this repo

| Role | Assumable from | Purpose |
|---|---|---|
| `baseline-plan` | `repo:<owner>@<owner_id>/aws-account-baseline@<repo_id>:pull_request` | `terraform plan` (read-only + state read) |
| `baseline-apply` | `repo:<owner>@<owner_id>/aws-account-baseline@<repo_id>:environment:production` | `terraform apply` |

`baseline-apply` may manage IAM (OIDC provider, `cv-site-*`, `baseline-*` roles/policies),
CloudTrail, Budgets, and the state and trail buckets. `baseline-plan` gets read-only on those plus
read/write on the state lockfile object (plan needs the lock).

### 4.6 Budget

- Monthly cost budget, limit **USD 5**.
- Notifications by email to `var.alert_email`: **forecasted** spend > 40 % (USD 2) and **actual**
  spend > 100 % (USD 5).

### 4.7 CloudTrail

- One multi-region trail, management events only (the first copy is free), log file validation on.
- Dedicated S3 bucket `gf-cloudtrail-<account-id>` (via `modules/secure-bucket`): public access
  blocked, TLS-only, SSE-S3, versioned, objects expire after 90 days (noncurrent after 30), bucket
  policy granting CloudTrail write access only (scoped by `aws:SourceArn`).

## 5. Variables and outputs

**Variables:** `github_owner`, `alert_email`, `region` (default `eu-north-1`),
`cv_site_repo` (default `cv-site`), `baseline_repo` (default `aws-account-baseline`).

**Outputs:** `cv_site_deploy_role_arn`, `cv_site_preview_role_arn`, `baseline_plan_role_arn`,
`baseline_apply_role_arn`, `cloudtrail_bucket`.

`cv_site_*_role_arn` values are copied into the `cv-site` repo as GitHub Actions **secrets**, not
variables: both repos are public, GitHub prints `vars` unmasked in `with:` inputs and substituted
`run:` scripts, and an ARN embeds the account ID. This is the only interface between the two repos.

## 6. CI/CD

**`ci.yml`** (on pull request):

1. `terraform fmt -check -recursive`
2. `tflint` (with the AWS ruleset)
3. `checkov` (any skipped check must be an inline `#checkov:skip=<ID>:<justification>` comment on the resource)
4. Matrix `{terraform, tofu}`: `init -backend=false`, `validate`, `test`
5. `terraform plan` with `baseline-plan` via OIDC; plan summary posted as a PR comment

**`apply.yml`** (on push to `main`): runs in GitHub Environment `production` with a required
reviewer (Gonçalo), assumes `baseline-apply`, and runs `terraform apply` on the plan produced in
the same run.

## 7. Testing

`terraform test` with `mock_provider "aws"`. Required assertions:

- The OIDC trust policy of every role pins `aud` and a full `sub` (no `repo:*` wildcards).
- `cv-site-deploy` can only create roles when the `cv-site-boundary` boundary is set.
- Both buckets block all public access and deny non-TLS requests.
- The budget limit is 5 USD with the two notifications described in §4.6.
- The CloudTrail trail is multi-region with log file validation enabled.

## 8. Manual steps (documented in the README)

**Account context:** the account was created through AWS's newer "Sign up for AWS" flow and later
upgraded to the Paid plan with "advanced AWS features" activated. That makes it an AWS Organization
(a management account used only for org/billing admin, this project account, and an AWS-created
Identity Delegated Admin account), with AWS-managed SCPs already in place — including one that
restricts this account to `eu-north-1`/`us-east-1`/`us-west-2` (+ global/unspecified), which is why
`var.region` is constrained to that list (§5). There are no IAM users and no IAM Identity Center
setup by the owner.

1. Root user (management account): enable MFA; confirm no root access keys exist. It is used only
   for organization/billing admin, never for day-to-day work.
2. Day-to-day human access to the project account is `aws login --profile personal`, which opens a
   browser, authenticates with an AWS Builder ID, and lets you pick the project account's session
   (credentials refresh automatically for up to 12 h). If the Terraform AWS provider doesn't pick
   up those credentials automatically, export them first:
   `eval "$(aws configure export-credentials --profile personal --format env)"`.
3. Pre-flight: `aws cloudtrail describe-trails --include-shadow-trails` — if an organization or
   AWS-managed trail already records management events for this account, the trail this repo
   creates (§4.7) would be a second, paid copy; decide whether to import it into state or skip
   creating it before the first apply.
4. `cd bootstrap && terraform init && terraform apply` (local state).
5. Root module: `terraform init` (S3 backend) and first `terraform apply` locally. CI roles do
   not exist before this.
6. In GitHub: create Environment `production` with a required reviewer; set repo **secrets**
   `AWS_ROLE_PLAN`, `AWS_ROLE_APPLY`, `TF_STATE_BUCKET` and `ALERT_EMAIL` (both repos are public,
   so ARNs and the alert address must not be `vars`, which print unmasked in logs). Set
   `AWS_ROLE_PLAN`, `TF_STATE_BUCKET` and `ALERT_EMAIL` again scoped to Dependabot
   (`gh secret set NAME --app dependabot ...`), since Dependabot PRs only receive Dependabot's
   own secrets and `plan` is a required check.
7. Copy the `cv_site_*_role_arn` outputs into the `cv-site` repo, also as secrets.

(Budget email subscribers need no confirmation.)

## 9. Cost

About USD 0/month: IAM, OIDC, Budgets (first two free) and a management-events trail are free;
S3 for state and trail logs costs cents.

## 10. Error handling and operations

- Plans that would destroy IAM roles or the OIDC provider are visible in the PR comment and need
  the required reviewer to apply.
- The state bucket is versioned, so a corrupted state can be restored from a previous version.
- Recovering from lockout (for example a broken trust policy) is done locally with `aws login
  --profile personal` (browser-based session, project account). This is documented in the README.

## Implementation notes (post-review)

The shipped code is stricter than this spec in a few places, tightened during code review:

- **`cv-site-deploy` uses explicit action lists**, not service wildcards, everywhere resource-level
  scoping is possible (S3, Lambda, CloudWatch Logs, SSM, SES). SES is limited to identity
  management (`CreateEmailIdentity`, `GetEmailIdentity`, DKIM, tags) — no identity policies or
  sending-authorization actions. S3 write access on `cv-site-*` buckets is conditioned on
  `aws:ResourceAccount` (except `s3:CreateBucket`, which cannot carry that condition since the
  bucket doesn't exist yet). `lambda:AddPermission`/`RemovePermission` is conditioned on
  `lambda:Principal = apigateway.amazonaws.com`, so the role can only wire up API Gateway
  invocations, not grant invoke to an arbitrary principal.
- **IAM deny statements go further than the spec's single deny.** Beyond denying changes to
  `cv-site-boundary` and IAM actions on `baseline-*`, `cv-site-deploy` explicitly denies all IAM
  actions on the two CI role ARNs (`cv-site-deploy`, `cv-site-preview` themselves) and denies
  removing or bypassing its own permissions boundary.
- **`baseline-plan`'s IAM read access is `iam:Get*`/`iam:List*` on `*`**, not scoped to specific
  roles, because Terraform's plan-time refresh reads the full IAM state of every resource in
  state, and no resource-level condition key restricts read-only IAM calls the way write calls can
  be restricted. This is called out as an accepted residual risk in the README.
- **The CloudTrail bucket policy (via `modules/secure-bucket`) has no object-level access for
  `baseline-apply`** beyond what CloudTrail itself needs to write logs: Terraform never reads or
  writes trail objects, so the apply role's `s3:*` on the bucket ARN deliberately excludes the
  `/*` object suffix. This is defence in depth, not a hard control — bucket-level `s3:*` still
  lets the role rewrite the bucket policy or lifecycle rules, and combined with `iam:*` on its own role, `baseline-apply` is
  effectively account-admin-equivalent; the real control is the `production` environment's
  required reviewer (see the README's accepted residual risks).
- **checkov skips are narrower than a first pass suggested**: two skips were removed during review
  (`5967f51`, `30c260c`) because the checks either didn't fire in checkov 3.x or the skip
  description was misleading; only skips for checks that actually trigger remain, each with an
  inline justification.
- **Lock-file handling is more involved than "just run terraform test"**: the committed
  `.terraform.lock.hcl` files are Terraform's; OpenTofu resolves a different registry address, so
  the Makefile backs up and restores each directory's lock file around any `TF=tofu` run and uses
  `-lockfile=readonly` for plain Terraform. See the README's "Local development" section.
- All of the above properties (least privilege, no escalation, boundary enforcement, deny-lists)
  are asserted by `tests/*.tftest.hcl` with allow-list/exact-match assertions (not just "contains"
  checks), and were exercised with mutation testing during review — a broadened statement or a
  dropped condition makes the corresponding test fail.
- **Adapted to the account actually applied to**, once its real shape was confirmed: the region
  choice moved to `eu-north-1` (the SCP-fixed home region for this project account, replacing the
  original Ireland-region choice), `var.region` gained a validation restricting it to the SCP's
  allowed regions (`eu-north-1`/`us-east-1`/`us-west-2`), and every reference to IAM Identity
  Center / `aws configure sso` was replaced with the account's actual access model (browser-based
  `aws login` sessions; no IAM users). See §8 and the README for the current steps, and the
  README's "First-time setup" for the CloudTrail pre-flight check needed before the trail in §4.7
  is applied (an org-level trail may already cover this account).
- **Tagging policy added after the initial review** (owner-approved, same standard as `cv-site`):
  a pure `modules/tags` module validates `Component`/`Environment`/`ManagedBy`/`Repository` and
  fixes `Project`/`Owner`, and both roots feed its output into the AWS provider's `default_tags`,
  so every resource is created already tagged. Full policy, rationale and enforcement in both
  repos: `docs/tagging-policy.md`.
- **Immutable OIDC subjects (production incident, after the first apply)**: the first CI apply
  failed with `AccessDenied` on `AssumeRoleWithWebIdentity`. CloudTrail's `principalId` revealed that
  GitHub now sends immutable subjects (`repo:goncalofileno@<owner_id>/aws-account-baseline@<repo_id>:environment:production`),
  not the `repo:<owner>/<repo>:<claim>` form the trust policies expected; the repos'
  `actions/oidc/customization/sub` setting confirmed `use_immutable_subject: true`. The module now takes
  `github_owner_id` and `github_repo_id` and builds `repo:<owner>@<owner_id>/<repo>@<repo_id>:<claim>`,
  the root has `github_owner_id`, `baseline_repo_id` and `cv_site_repo_id` variables (public GitHub
  metadata), and the tests expect the new format. The updated trust policies were applied locally via
  the README's documented recovery path. This makes a renamed or re-created repo unable to inherit access.
