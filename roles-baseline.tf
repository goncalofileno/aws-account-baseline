locals {
  state_bucket_arn = "arn:aws:s3:::${local.state_bucket_name}"
  trail_bucket_arn = "arn:aws:s3:::${local.trail_bucket_name}"
  budget_arns      = "arn:aws:budgets::${local.account_id}:budget/*"
  # Cost Anomaly Detection (Cost Explorer) ARNs are global: no region segment.
  anomaly_arns = [
    "arn:aws:ce::${local.account_id}:anomalymonitor/*",
    "arn:aws:ce::${local.account_id}:anomalysubscription/*",
  ]

  # Cost kill switch (kill-switch.tf, spec docs/specs/2026-11-09-cost-kill-switch-design.md). No name
  # starts with cv-site-, so the cv-site roles can't change it; its IAM roles are baseline-*, which
  # ManagedIam below already covers.
  kill_switch_function_arn  = "arn:aws:lambda:${var.region}:${local.account_id}:function:cost-kill-switch"
  kill_switch_topic_arns    = "arn:aws:sns:${var.region}:${local.account_id}:cost-kill-switch-*"
  kill_switch_schedule_arns = "arn:aws:scheduler:${var.region}:${local.account_id}:schedule/default/cost-kill-switch-*"
  kill_switch_parameter_arn = "arn:aws:ssm:${var.region}:${local.account_id}:parameter/cost-kill-switch/state"
  kill_switch_alarm_arns    = "arn:aws:cloudwatch:${var.region}:${local.account_id}:alarm:cost-kill-switch-*"
  kill_switch_log_groups = [
    "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/lambda/cost-kill-switch",
    "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/lambda/cost-kill-switch:*",
  ]

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
      { Sid = "AnomalyDetectionRead", Effect = "Allow", Action = ["ce:GetAnomalyMonitors", "ce:GetAnomalySubscriptions", "ce:ListTagsForResource"], Resource = local.anomaly_arns },
      { Sid = "KillSwitchFunctionRead", Effect = "Allow", Action = ["lambda:Get*", "lambda:List*"], Resource = local.kill_switch_function_arn },
      { Sid = "KillSwitchTopicsRead", Effect = "Allow", Action = ["sns:Get*", "sns:List*"], Resource = local.kill_switch_topic_arns },
      { Sid = "KillSwitchScheduleRead", Effect = "Allow", Action = ["scheduler:GetSchedule"], Resource = local.kill_switch_schedule_arns },
      { Sid = "KillSwitchStateRead", Effect = "Allow", Action = ["ssm:GetParameter", "ssm:ListTagsForResource"], Resource = local.kill_switch_parameter_arn },
      { Sid = "KillSwitchAlarmsRead", Effect = "Allow", Action = ["cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource"], Resource = local.kill_switch_alarm_arns },
      { Sid = "KillSwitchLogsRead", Effect = "Allow", Action = ["logs:ListTagsForResource", "logs:ListTagsLogGroup"], Resource = local.kill_switch_log_groups },
      { Sid = "KillSwitchDescribe", Effect = "Allow", Action = ["ssm:DescribeParameters", "logs:DescribeLogGroups"], Resource = "*" },
      { Sid = "AccountPublicAccessBlockRead", Effect = "Allow", Action = ["s3:GetAccountPublicAccessBlock"], Resource = "*" },
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
      # ce:CreateAnomalyMonitor and ce:CreateAnomalySubscription have no resource type in the IAM
      # service authorization reference (the ARN doesn't exist until the call returns), so "*" is
      # the only valid Resource. They can only create cost-monitoring objects in this account.
      # Tag-on-create is authorised as ce:TagResource on the new ARN (AnomalyDetection below).
      { Sid = "AnomalyDetectionCreate", Effect = "Allow", Action = ["ce:CreateAnomalyMonitor", "ce:CreateAnomalySubscription"], Resource = "*" },
      {
        Sid    = "AnomalyDetection"
        Effect = "Allow"
        Action = [
          "ce:GetAnomalyMonitors", "ce:UpdateAnomalyMonitor", "ce:DeleteAnomalyMonitor",
          "ce:GetAnomalySubscriptions", "ce:UpdateAnomalySubscription", "ce:DeleteAnomalySubscription",
          "ce:TagResource", "ce:UntagResource", "ce:ListTagsForResource",
        ]
        Resource = local.anomaly_arns
      },
      # Cost kill switch resources, each scoped to the cost-kill-switch names. Its IAM roles
      # (baseline-*) and their PassRole are covered by ManagedIam above.
      { Sid = "KillSwitchFunction", Effect = "Allow", Action = ["lambda:*"], Resource = local.kill_switch_function_arn },
      { Sid = "KillSwitchTopics", Effect = "Allow", Action = ["sns:*"], Resource = local.kill_switch_topic_arns },
      { Sid = "KillSwitchSchedule", Effect = "Allow", Action = ["scheduler:*"], Resource = local.kill_switch_schedule_arns },
      { Sid = "KillSwitchState", Effect = "Allow", Action = ["ssm:*"], Resource = local.kill_switch_parameter_arn },
      {
        Sid      = "KillSwitchAlarms"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:DescribeAlarms", "cloudwatch:TagResource", "cloudwatch:UntagResource", "cloudwatch:ListTagsForResource"]
        Resource = local.kill_switch_alarm_arns
      },
      { Sid = "KillSwitchLogs", Effect = "Allow", Action = ["logs:*"], Resource = local.kill_switch_log_groups },
      { Sid = "KillSwitchDescribe", Effect = "Allow", Action = ["ssm:DescribeParameters", "logs:DescribeLogGroups"], Resource = "*" },
      # The account-level S3 Block Public Access setting has no resource ARN, so "*" is the only Resource.
      { Sid = "AccountPublicAccessBlock", Effect = "Allow", Action = ["s3:GetAccountPublicAccessBlock", "s3:PutAccountPublicAccessBlock"], Resource = "*" },
    ]
  })
}

module "baseline_plan" {
  source = "./modules/github-oidc-role"

  name              = "baseline-plan"
  description       = "GitHub Actions read-only role for terraform plan on ${var.github_owner}/${var.baseline_repo} pull requests."
  oidc_provider_arn = aws_iam_openid_connect_provider.github.arn
  github_owner      = var.github_owner
  github_owner_id   = var.github_owner_id
  github_repo       = var.baseline_repo
  github_repo_id    = var.baseline_repo_id
  subject_claims    = ["pull_request"]
  policy_json       = local.baseline_plan_policy
}

module "baseline_apply" {
  source = "./modules/github-oidc-role"

  name              = "baseline-apply"
  description       = "GitHub Actions role for terraform apply on ${var.github_owner}/${var.baseline_repo} (production environment only)."
  oidc_provider_arn = aws_iam_openid_connect_provider.github.arn
  github_owner      = var.github_owner
  github_owner_id   = var.github_owner_id
  github_repo       = var.baseline_repo
  github_repo_id    = var.baseline_repo_id
  subject_claims    = ["environment:production"]
  policy_json       = local.baseline_apply_policy
}
