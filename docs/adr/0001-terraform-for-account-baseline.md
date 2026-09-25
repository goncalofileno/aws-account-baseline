# ADR 0001: Terraform for the account baseline, Pulumi for the site

- Status: Accepted
- Date: 2026-09-24

## Context

My personal AWS account hosts my CV site. Before the site's pipeline can deploy, the account needs
some groundwork: a GitHub OIDC provider, deploy roles, a cost budget and an audit trail. I use Pulumi
daily at work. Terraform is still the infrastructure-as-code tool that job postings ask for most.

## Decision

- The account baseline (this repo) is written in **Terraform** and CI-tested with **OpenTofu**.
- The site (`cv-site`) uses **Pulumi (TypeScript)** and consumes the role ARNs exported here.

## Consequences

- Mirrors a common split: a platform layer in Terraform, application stacks in Pulumi/CDK.
- Two IaC tools to maintain. The interface between them is small and explicit: two role ARNs passed
  as GitHub variables.
- The baseline must be applied before the site's first deploy.
