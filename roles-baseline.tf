locals {
  state_bucket_arn = "arn:aws:s3:::${local.state_bucket_name}"
  trail_bucket_arn = "arn:aws:s3:::${local.trail_bucket_name}"
  budget_arns      = "arn:aws:budgets::${local.account_id}:budget/*"

  s3_bucket_config_read = [
    "s3:GetBucket*", "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration",
    "s3:GetAccelerateConfiguration", "s3:GetReplicationConfiguration", "s3:ListBucket",
  ]

  baseline_plan_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "StateList", Effect = "Allow", Action = ["s3:ListBucket"], Resource = local.state_bucket_arn },
      { Sid = "StateRead", Effect = "Allow", Action = ["s3:GetObject"], Resource = "${local.state_bucket_arn}/${local.state_key}" },
      { Sid = "StateLock", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = ["${local.state_bucket_arn}/${local.state_key}.tflock"] },
      { Sid = "IamRead", Effect = "Allow", Action = ["iam:Get*", "iam:List*"], Resource = "*" },
      { Sid = "CloudTrailRead", Effect = "Allow", Action = ["cloudtrail:Describe*", "cloudtrail:Get*", "cloudtrail:List*"], Resource = "*" },
      { Sid = "BudgetsRead", Effect = "Allow", Action = ["budgets:ViewBudget", "budgets:ListTagsForResource"], Resource = local.budget_arns },
      { Sid = "TrailBucketConfigRead", Effect = "Allow", Action = local.s3_bucket_config_read, Resource = local.trail_bucket_arn },
    ]
  })

  baseline_apply_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "StateList", Effect = "Allow", Action = ["s3:ListBucket"], Resource = local.state_bucket_arn },
      { Sid = "StateReadWrite", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = "${local.state_bucket_arn}/${local.state_key}" },
      { Sid = "StateLock", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = ["${local.state_bucket_arn}/${local.state_key}.tflock"] },
      { Sid = "IamRead", Effect = "Allow", Action = ["iam:Get*", "iam:List*"], Resource = "*" },
      { Sid = "GithubOidcProvider", Effect = "Allow", Action = ["iam:*OpenIDConnectProvider*"], Resource = "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com" },
      # Includes baseline-apply itself: this repo manages its own CI roles. Applies are gated by
      # the GitHub "production" environment's required reviewer.
      {
        Sid    = "ManagedIam"
        Effect = "Allow"
        Action = "iam:*"
        Resource = [
          "arn:aws:iam::${local.account_id}:role/cv-site-*",
          "arn:aws:iam::${local.account_id}:role/baseline-*",
          "arn:aws:iam::${local.account_id}:policy/cv-site-*",
        ]
      },
      { Sid = "CloudTrailManage", Effect = "Allow", Action = "cloudtrail:*", Resource = local.trail_arn },
      { Sid = "CloudTrailRead", Effect = "Allow", Action = ["cloudtrail:Describe*", "cloudtrail:Get*", "cloudtrail:List*"], Resource = "*" },
      { Sid = "Budgets", Effect = "Allow", Action = ["budgets:ModifyBudget", "budgets:ViewBudget", "budgets:TagResource", "budgets:UntagResource", "budgets:ListTagsForResource"], Resource = local.budget_arns },
      # Object-level access (the "/*" suffix) is deliberately withheld: Terraform never reads or
      # writes CloudTrail log objects (no force_destroy on this bucket), so apply has no
      # legitimate reason to be able to overwrite or delete them. This is defence in depth, not a
      # hard control: bucket-level s3:* still lets this role rewrite the bucket policy or the
      # lifecycle rules (e.g. expire every object), and combined with ManagedIam's iam:* on its
      # own role above, baseline-apply is effectively account-admin-equivalent. The real control is the production environment's required
      # reviewer.
      { Sid = "TrailBucket", Effect = "Allow", Action = "s3:*", Resource = local.trail_bucket_arn },
    ]
  })
}

module "baseline_plan" {
  source = "./modules/github-oidc-role"

  name              = "baseline-plan"
  description       = "GitHub Actions read-only role for terraform plan on ${var.github_owner}/${var.baseline_repo} pull requests."
  oidc_provider_arn = aws_iam_openid_connect_provider.github.arn
  github_owner      = var.github_owner
  github_repo       = var.baseline_repo
  subject_claims    = ["pull_request"]
  policy_json       = local.baseline_plan_policy
}

module "baseline_apply" {
  source = "./modules/github-oidc-role"

  name              = "baseline-apply"
  description       = "GitHub Actions role for terraform apply on ${var.github_owner}/${var.baseline_repo} (production environment only)."
  oidc_provider_arn = aws_iam_openid_connect_provider.github.arn
  github_owner      = var.github_owner
  github_repo       = var.baseline_repo
  subject_claims    = ["environment:production"]
  policy_json       = local.baseline_apply_policy
}
