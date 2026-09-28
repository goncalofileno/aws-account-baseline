# Tagging policy

Owner-approved policy for every AWS resource in the `cv-site` portfolio (this repo and `cv-site`).
The goal is that every resource is created already correctly tagged — there is no drift-detection
or backfill step, tagging is enforced at plan/apply time, before anything reaches AWS.

## Required tags

| Key | Allowed values | Rationale |
|---|---|---|
| `Project` | `cv-site` | One portfolio, one value. Groups every resource across both repos and both accounts' cost/usage views under a single project, even though it's technically only ever this one value today. |
| `Component` | `tf-state`, `account-baseline`, `web`, `contact-api`, `dns` | The unit of the architecture a resource belongs to (state bucket, this baseline, the static site, the contact-form Lambda/API, DNS). Lets cost and change-history be sliced below "whole project". |
| `Environment` | `prod`, `shared` | Distinguishes resources that exist once per environment (`prod`, the only environment this portfolio has) from ones shared infrastructure that isn't environment-scoped (state, CI roles, the audit trail). There is no `staging` yet (see the backlog), so adding it later just means widening this allow-list. |
| `ManagedBy` | `terraform`, `pulumi` | Which IaC tool owns the resource's lifecycle — useful when reading a resource in the console to know which repo and `apply`/`up` created it, and to keep one tool from accidentally managing (and deleting) the other's resources. |
| `Repository` | `github.com/goncalofileno/<repo>` (regex `^github\.com/goncalofileno/[A-Za-z0-9._-]+$`) | Exact source of truth for the code that created the resource. Fixed to this account owner's GitHub login; the value differs only in the trailing repo name (`aws-account-baseline` or `cv-site`). |
| `Owner` | `goncalo-fileno` | Single-person account today, but explicit rather than implied — matters if the account is ever shared or audited by someone else. |

All keys are PascalCase, matching AWS's own tag conventions (e.g. `aws:cloudformation:stack-name`) and
what Cost Explorer displays.

## Assignments used by this repo

| Root | `Component` | `Environment` | `ManagedBy` | `Repository` |
|---|---|---|---|---|
| `bootstrap/` | `tf-state` | `shared` | `terraform` | `github.com/goncalofileno/aws-account-baseline` |
| root (`.`) | `account-baseline` | `shared` | `terraform` | `github.com/goncalofileno/aws-account-baseline` |

`Project` is always `cv-site` and `Owner` is always `goncalo-fileno` in both roots.

`cv-site` (the Pulumi repo) uses `Environment = prod` throughout, and `Component` per module: `web`
for the static site, `contact-api` for the Lambda/API Gateway path, `dns` for the Cloudflare-adjacent
AWS resources (e.g. the ACM certificate). Its `ManagedBy` is `pulumi` and its `Repository` is
`github.com/goncalofileno/cv-site`.

## Enforcement

- **Terraform (this repo):** `modules/tags` is a pure module (no resources, no provider) that takes
  `component`, `environment`, `managed_by` (default `terraform`) and `repository`, validates each
  against the table above, and outputs the full six-key map (`Project` and `Owner` are constants
  inside the module, not inputs — every caller gets the same values for free and can't drift them).
  Both the root module and `bootstrap/` call it once and hand its output to the AWS provider's
  `default_tags { tags = ... }`, so every taggable resource either root creates is tagged
  automatically, with no per-resource `tags = {...}` blocks to keep in sync or forget.
  `tests/tags.tftest.hcl` exercises the module directly (valid input → exact map; one
  `expect_failures` run per invalid value), and `tests/variables.tftest.hcl` /
  `bootstrap/tests/bootstrap.tftest.hcl` each assert the exact tag map the corresponding root
  produces. All of this runs under `terraform test`/`tofu test` with mock providers, so it's
  checked on every PR before anything is ever applied.
- **Pulumi (`cv-site`):** the same values are set once through the AWS provider's `defaultTags`
  (default provider and the `us-east-1` provider used for the CloudFront/ACM certificate), with
  `Component` set per module (`site.ts` → `web`, `contact-api.ts` → `contact-api`, DNS-adjacent
  resources → `dns`). An infra unit test (Pulumi mocks) asserts that every taggable AWS resource the
  program creates carries all six keys with allowed values, the same allow-list/exact-match style
  used here.

## Known gaps: non-taggable resources

A handful of sub-resources this repo's modules create have no `tags` argument at all — for example
`aws_s3_bucket_public_access_block`, `aws_s3_bucket_versioning`, `aws_s3_bucket_policy` and
`aws_iam_openid_connect_provider`'s underlying trust configuration. These inherit nothing from
`default_tags` (AWS doesn't support tagging them), which is expected and not a policy violation:
they are attributes/sub-configuration of an already-tagged parent resource (the bucket, the role),
not independently billed or independently discoverable resources.

## Manual step: activate cost allocation tags

Tags only appear in Cost Explorer once they're activated as **cost allocation tags**, and AWS only
lists a tag key as a candidate after it has seen that key on at least one resource. So, once the
first `apply` has run (see `docs/PROGRESS.md` in `cv-site` — this is the one step in this policy that
needs a human, not code):

1. Sign in to the **management account**.
2. **Billing and Cost Management → Cost allocation tags**.
3. Activate `Project`, `Component` and `Environment` (the three that make sense to break cost down
   by; `ManagedBy`, `Repository` and `Owner` are for identification, not cost-splitting, so they're
   optional to activate).
4. Tags can take up to ~24 h to appear in the activation list and in Cost Explorer after the
   resources carrying them are created.

## Possible later enforcement layer

AWS Organizations **Tag Policies** (management account) could enforce this same allow-list at the
organization level — rejecting a tag value outside the table above even if it somehow got past
Terraform/Pulumi's own validation (e.g. a manual console change). This is listed in `cv-site`'s
`docs/PROGRESS.md` backlog rather than implemented now: it needs an AWS Organizations policy
resource in the management account, which is out of scope for this project account's baseline.
