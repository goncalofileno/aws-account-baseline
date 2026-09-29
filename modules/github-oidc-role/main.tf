locals {
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "GitHubActionsOIDC"
        Effect    = "Allow"
        Principal = { Federated = var.oidc_provider_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = [for c in var.subject_claims : "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}:${c}"]
          }
        }
      },
    ]
  })
}

resource "aws_iam_role" "this" {
  name                 = var.name
  description          = var.description
  assume_role_policy   = local.assume_role_policy
  permissions_boundary = var.permissions_boundary_arn
  max_session_duration = var.max_session_duration
}

resource "aws_iam_role_policy" "this" {
  #checkov:skip=CKV_AWS_355:Policies are passed in by callers, documented in roles-*.tf and asserted by tests/*.tftest.hcl (boundary, deny statements, read-only checks)
  #checkov:skip=CKV2_AWS_40:Fires for baseline-apply only; iam:* is intentional (it manages the cv-site-* and baseline-* roles and policies), is scoped to those ARNs, pinned by exact statement tests and gated by the production environment reviewer
  name   = "${var.name}-policy"
  role   = aws_iam_role.this.id
  policy = var.policy_json
}
