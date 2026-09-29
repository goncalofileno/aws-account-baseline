# CLAUDE.md

Context for Claude Code sessions on this repo, on any machine.

## What this is

Terraform baseline for Gonçalo Fileno's personal AWS account: GitHub OIDC provider, least-privilege CI
roles for `cv-site` and for this repo, a USD 5 budget and a CloudTrail trail. It is sub-project 0 of
his CV site (`../cv-site`, see its `CLAUDE.md`). The design is in `docs/specs/`. Project-wide progress
(including this repo) is tracked in `cv-site`'s `docs/PROGRESS.md`. Update it when you finish work here.

## Working agreements

- Talk to Gonçalo in European Portuguese (pt-PT). Everything committed is in English.
- Never ask for credentials in chat. He runs `aws login --profile personal` (browser-based,
  project-account session) and `gh auth login`, and types secret values into prompts himself.
- Public repo: no email or AWS account ID in committed files or CI logs (CI prints summaries only).
- Keep cost at about USD 0/month.
- Every change: `make check` (fmt, validate, tflint, checkov, tests) and `make test TF=tofu` must
  pass. Tests use mock providers and never touch AWS.
- checkov skips are inline `#checkov:skip=<ID>:<reason>` comments, never global.
- IAM policies are built with `jsonencode()` so the tests can assert on them.
- Any IAM change (roles, policies, boundary, deny statements) must keep the allow-list/exact-match
  assertions in `tests/*.tftest.hcl` passing, and should be mutation-checked: temporarily broaden a
  statement or drop a condition and confirm the relevant test fails before reverting.
- OIDC trust uses GitHub immutable subjects: `repo:<owner>@<id>/<repo>@<id>:<claim>` (IDs from
  `gh api repos/OWNER/REPO/actions/oidc/customization/sub -q .sub_claim_prefix`).
- Every resource carries the required tags from `docs/tagging-policy.md`.

## Change flow

A PR gets CI checks and a plan summary comment. After the merge, the `production` environment needs
approval, then the apply runs. Local recovery uses `aws login --profile personal` (see README →
Recovery).
