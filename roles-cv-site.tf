locals {
  cv_site_role_arns    = "arn:aws:iam::${local.account_id}:role/cv-site-*"
  cv_site_ci_role_arns = ["arn:aws:iam::${local.account_id}:role/cv-site-deploy", "arn:aws:iam::${local.account_id}:role/cv-site-preview"]
  cv_site_buckets      = ["arn:aws:s3:::cv-site-*", "arn:aws:s3:::cv-site-*/*"]
  cv_site_functions    = "arn:aws:lambda:${var.region}:${local.account_id}:function:cv-site-*"
  cv_site_log_groups = [
    "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/lambda/cv-site-*",
    "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/lambda/cv-site-*:*",
  ]
  cv_site_parameters = "arn:aws:ssm:${var.region}:${local.account_id}:parameter/cv-site/*"
  cv_site_apis = [
    "arn:aws:apigateway:${var.region}::/apis",
    "arn:aws:apigateway:${var.region}::/apis/*",
    "arn:aws:apigateway:${var.region}::/tags/*",
  ]
  ssm_kms_condition = { StringEquals = { "kms:ViaService" = "ssm.${var.region}.amazonaws.com" } }
  # CloudFront publishes its metrics only in us-east-1, so the site's traffic alarms live there.
  # The account's region SCP allows CloudWatch in us-east-1 but denies SNS (and EventBridge), so
  # the alarms email the owner through AWS User Notifications instead of an SNS topic.
  cv_site_alarms = "arn:aws:cloudwatch:us-east-1:${local.account_id}:alarm:cv-site-*"
  # Exactly the AWS User Notifications calls the Pulumi provider makes for a notification hub, a
  # notification configuration with one event rule, and one email contact associated as its
  # channel. Some of them (the hub and List calls) take no resource type, and the ARNs of the
  # rest end in random IDs, so they are granted on "*": this account only hosts cv-site, and an
  # email contact receives nothing until its owner clicks the activation link AWS sends it.
  cv_site_notification_actions = [
    "notifications:RegisterNotificationHub", "notifications:DeregisterNotificationHub", "notifications:ListNotificationHubs",
    "notifications:CreateNotificationConfiguration", "notifications:GetNotificationConfiguration",
    "notifications:UpdateNotificationConfiguration", "notifications:DeleteNotificationConfiguration",
    "notifications:CreateEventRule", "notifications:GetEventRule", "notifications:UpdateEventRule",
    "notifications:DeleteEventRule", "notifications:ListEventRules",
    "notifications:AssociateChannel", "notifications:DisassociateChannel", "notifications:ListChannels",
    "notifications:TagResource", "notifications:UntagResource", "notifications:ListTagsForResource",
    "notifications-contacts:CreateEmailContact", "notifications-contacts:GetEmailContact",
    "notifications-contacts:DeleteEmailContact", "notifications-contacts:ListEmailContacts",
    "notifications-contacts:SendActivationCode",
    "notifications-contacts:TagResource", "notifications-contacts:UntagResource", "notifications-contacts:ListTagsForResource",
  ]
}

# Permissions boundary attached to every role the cv-site Pulumi stack creates (the Lambda
# execution role). Even if the deploy role writes a broad inline policy, this caps it.
resource "aws_iam_policy" "cv_site_boundary" {
  name        = "cv-site-boundary"
  description = "Permissions boundary for IAM roles created by the cv-site stack."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "LambdaLogs", Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = local.cv_site_log_groups },
      { Sid = "ReadOwnParameters", Effect = "Allow", Action = ["ssm:GetParameter"], Resource = local.cv_site_parameters },
      { Sid = "DecryptParametersViaSsm", Effect = "Allow", Action = ["kms:Decrypt"], Resource = "*", Condition = local.ssm_kms_condition },
      { Sid = "SendEmail", Effect = "Allow", Action = ["ses:SendEmail", "ses:SendRawEmail"], Resource = "arn:aws:ses:${var.region}:${local.account_id}:identity/*" },
    ]
  })
}

# Residual risk IAM cannot close: cv-site-deploy can create/retrust cv-site-* roles' trust
# policies (no IAM condition key constrains the Principal of a trust policy), so it could in
# principle create a role trusted by a different, less-restricted identity. This is capped by
# the cv-site-boundary permissions boundary on the role's own permissions (not its trust policy)
# and otherwise depends on branch protection on cv-site's main branch, since this role is only
# assumable from that branch's CI.
locals {
  cv_site_deploy_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # s3:CreateBucket must stay unconditioned: the bucket doesn't exist yet when this action
      # runs, so aws:ResourceAccount (a property of an existing resource) would not evaluate as
      # expected. Creating a bucket always creates it in the caller's own account regardless.
      { Sid = "CreateSiteBuckets", Effect = "Allow", Action = ["s3:CreateBucket"], Resource = local.cv_site_buckets },
      {
        Sid       = "SiteBuckets"
        Effect    = "Allow"
        Action    = "s3:*"
        Resource  = local.cv_site_buckets
        Condition = { StringEquals = { "aws:ResourceAccount" = local.account_id } }
      },
      # CloudFront create actions do not support resource-level permissions.
      {
        Sid    = "CloudFront"
        Effect = "Allow"
        Action = [
          "cloudfront:CreateDistribution", "cloudfront:CreateDistributionWithTags", "cloudfront:UpdateDistribution", "cloudfront:DeleteDistribution",
          "cloudfront:CreateInvalidation", "cloudfront:TagResource", "cloudfront:UntagResource",
          "cloudfront:CreateFunction", "cloudfront:UpdateFunction", "cloudfront:DeleteFunction", "cloudfront:PublishFunction", "cloudfront:DescribeFunction", "cloudfront:TestFunction",
          "cloudfront:CreateOriginAccessControl", "cloudfront:UpdateOriginAccessControl", "cloudfront:DeleteOriginAccessControl",
          "cloudfront:CreateResponseHeadersPolicy", "cloudfront:UpdateResponseHeadersPolicy", "cloudfront:DeleteResponseHeadersPolicy",
          "cloudfront:CreateCachePolicy", "cloudfront:UpdateCachePolicy", "cloudfront:DeleteCachePolicy",
          "cloudfront:CreateOriginRequestPolicy", "cloudfront:UpdateOriginRequestPolicy", "cloudfront:DeleteOriginRequestPolicy",
          "cloudfront:Get*", "cloudfront:List*",
        ]
        Resource = "*"
      },
      {
        Sid       = "AcmForCloudFront"
        Effect    = "Allow"
        Action    = ["acm:RequestCertificate", "acm:DeleteCertificate", "acm:DescribeCertificate", "acm:GetCertificate", "acm:ListCertificates", "acm:ListTagsForCertificate", "acm:AddTagsToCertificate", "acm:RemoveTagsFromCertificate"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = "us-east-1" } }
      },
      {
        Sid    = "SiteFunctions"
        Effect = "Allow"
        Action = [
          "lambda:Get*", "lambda:List*", "lambda:CreateFunction", "lambda:DeleteFunction",
          "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration", "lambda:PublishVersion",
          "lambda:PutFunctionConcurrency", "lambda:TagResource", "lambda:UntagResource",
        ]
        Resource = local.cv_site_functions
      },
      # Pulumi's aws.lambda.Permission for API Gateway invocation always uses this principal;
      # scoping it here means the deploy role can't grant invoke access to some other principal.
      {
        Sid       = "SiteFunctionPermissions"
        Effect    = "Allow"
        Action    = ["lambda:AddPermission", "lambda:RemovePermission"]
        Resource  = local.cv_site_functions
        Condition = { StringEquals = { "lambda:Principal" = "apigateway.amazonaws.com" } }
      },
      # API Gateway v2 only supports path-style resources, scoped here to the region's APIs.
      # Tag-on-create (stages, APIs) is authorised as apigateway:TagResource on the new resource.
      { Sid = "HttpApis", Effect = "Allow", Action = ["apigateway:GET", "apigateway:POST", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE", "apigateway:TagResource", "apigateway:UntagResource"], Resource = local.cv_site_apis },
      {
        Sid      = "SiteLogGroups"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy", "logs:TagResource", "logs:UntagResource", "logs:ListTagsForResource", "logs:TagLogGroup", "logs:ListTagsLogGroup"]
        Resource = local.cv_site_log_groups
      },
      { Sid = "DescribeLogGroups", Effect = "Allow", Action = ["logs:DescribeLogGroups"], Resource = "*" },
      {
        Sid      = "SiteParameters"
        Effect   = "Allow"
        Action   = ["ssm:PutParameter", "ssm:GetParameter", "ssm:GetParameters", "ssm:DeleteParameter", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource", "ssm:LabelParameterVersion"]
        Resource = local.cv_site_parameters
      },
      { Sid = "DescribeParameters", Effect = "Allow", Action = ["ssm:DescribeParameters"], Resource = "*" },
      { Sid = "SsmKmsViaService", Effect = "Allow", Action = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"], Resource = "*", Condition = local.ssm_kms_condition },
      {
        Sid      = "SesIdentityManagement"
        Effect   = "Allow"
        Action   = ["ses:CreateEmailIdentity", "ses:DeleteEmailIdentity", "ses:GetEmailIdentity", "ses:PutEmailIdentityDkimAttributes", "ses:TagResource", "ses:UntagResource", "ses:ListTagsForResource"]
        Resource = "arn:aws:ses:${var.region}:${local.account_id}:identity/*"
      },
      { Sid = "SesListIdentities", Effect = "Allow", Action = ["ses:ListEmailIdentities"], Resource = "*" },
      # Every action below takes the alarm resource type, including DescribeAlarms: the Pulumi
      # provider reads an alarm with DescribeAlarms(AlarmNames, AlarmTypes = MetricAlarm), which a
      # scoped grant allows (only composite alarms need DescribeAlarms on "*"), and reads its tags
      # with ListTagsForResource. TagResource also covers tag-on-create in PutMetricAlarm.
      {
        Sid      = "SiteAlarms"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:DescribeAlarms", "cloudwatch:TagResource", "cloudwatch:UntagResource", "cloudwatch:ListTagsForResource"]
        Resource = local.cv_site_alarms
      },
      { Sid = "SiteAlertNotifications", Effect = "Allow", Action = local.cv_site_notification_actions, Resource = "*" },
      # Read-only: lets the deploy workflow mask the organization and management account IDs
      # before any step can print them (an SCP denial message quotes the SCP's ARN, which holds both).
      { Sid = "DescribeOrganization", Effect = "Allow", Action = ["organizations:DescribeOrganization"], Resource = "*" },
      # Read-only: the deploy workflow refuses to deploy while the cost kill switch is tripped
      # (kill-switch.tf). The role can read the state but never change it.
      { Sid = "KillSwitchState", Effect = "Allow", Action = ["ssm:GetParameter"], Resource = local.kill_switch_parameter_arn },
      {
        Sid       = "CreateRolesOnlyWithBoundary"
        Effect    = "Allow"
        Action    = ["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:DeleteRolePolicy", "iam:PutRolePermissionsBoundary"]
        Resource  = local.cv_site_role_arns
        Condition = { StringEquals = { "iam:PermissionsBoundary" = aws_iam_policy.cv_site_boundary.arn } }
      },
      {
        Sid      = "ManageSiteRoles"
        Effect   = "Allow"
        Action   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole", "iam:TagRole", "iam:UntagRole", "iam:UpdateRole", "iam:UpdateRoleDescription", "iam:UpdateAssumeRolePolicy", "iam:DeleteRole"]
        Resource = local.cv_site_role_arns
      },
      {
        Sid       = "PassSiteRolesToLambda"
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = local.cv_site_role_arns
        Condition = { StringEquals = { "iam:PassedToService" = "lambda.amazonaws.com" } }
      },
      { Sid = "ReadBoundaryPolicy", Effect = "Allow", Action = ["iam:GetPolicy", "iam:GetPolicyVersion"], Resource = aws_iam_policy.cv_site_boundary.arn },
      { Sid = "DenyTouchingCiRoles", Effect = "Deny", Action = "iam:*", Resource = local.cv_site_ci_role_arns },
      { Sid = "DenyRemovingBoundary", Effect = "Deny", Action = ["iam:DeleteRolePermissionsBoundary"], Resource = local.cv_site_role_arns },
      { Sid = "DenyChangingBoundaryPolicy", Effect = "Deny", Action = ["iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion"], Resource = aws_iam_policy.cv_site_boundary.arn },
      { Sid = "DenyBaselineRoles", Effect = "Deny", Action = "iam:*", Resource = "arn:aws:iam::${local.account_id}:role/baseline-*" },
    ]
  })

  cv_site_preview_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "S3ReadBucketConfig"
        Effect    = "Allow"
        Action    = ["s3:GetBucket*", "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration", "s3:GetAccelerateConfiguration", "s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource  = "arn:aws:s3:::cv-site-*"
        Condition = { StringEquals = { "aws:ResourceAccount" = local.account_id } }
      },
      { Sid = "CloudFrontRead", Effect = "Allow", Action = ["cloudfront:Get*", "cloudfront:List*", "cloudfront:DescribeFunction"], Resource = "*" },
      { Sid = "AcmRead", Effect = "Allow", Action = ["acm:DescribeCertificate", "acm:ListCertificates", "acm:ListTagsForCertificate"], Resource = "*" },
      { Sid = "LambdaRead", Effect = "Allow", Action = ["lambda:Get*", "lambda:List*"], Resource = local.cv_site_functions },
      { Sid = "ApiRead", Effect = "Allow", Action = ["apigateway:GET"], Resource = local.cv_site_apis },
      { Sid = "LogsRead", Effect = "Allow", Action = ["logs:DescribeLogGroups", "logs:ListTagsForResource", "logs:ListTagsLogGroup"], Resource = "*" },
      { Sid = "SsmMetadataRead", Effect = "Allow", Action = ["ssm:DescribeParameters", "ssm:ListTagsForResource"], Resource = "*" },
      { Sid = "SesRead", Effect = "Allow", Action = ["ses:Get*", "ses:List*"], Resource = "*" },
      { Sid = "AlarmRead", Effect = "Allow", Action = ["cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource"], Resource = local.cv_site_alarms },
      { Sid = "AlertNotificationsRead", Effect = "Allow", Action = ["notifications:Get*", "notifications:List*", "notifications-contacts:Get*", "notifications-contacts:List*"], Resource = "*" },
      { Sid = "DescribeOrganization", Effect = "Allow", Action = ["organizations:DescribeOrganization"], Resource = "*" },
      { Sid = "IamRead", Effect = "Allow", Action = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"], Resource = local.cv_site_role_arns },
    ]
  })
}

module "cv_site_deploy" {
  source = "./modules/github-oidc-role"

  name              = "cv-site-deploy"
  description       = "GitHub Actions deploy role for ${var.github_owner}/${var.cv_site_repo} (main branch only)."
  oidc_provider_arn = aws_iam_openid_connect_provider.github.arn
  github_owner      = var.github_owner
  github_owner_id   = var.github_owner_id
  github_repo       = var.cv_site_repo
  github_repo_id    = var.cv_site_repo_id
  subject_claims    = ["ref:refs/heads/main"]
  policy_json       = local.cv_site_deploy_policy
}

module "cv_site_preview" {
  source = "./modules/github-oidc-role"

  name              = "cv-site-preview"
  description       = "GitHub Actions read-only role for pulumi preview on ${var.github_owner}/${var.cv_site_repo} pull requests."
  oidc_provider_arn = aws_iam_openid_connect_provider.github.arn
  github_owner      = var.github_owner
  github_owner_id   = var.github_owner_id
  github_repo       = var.cv_site_repo
  github_repo_id    = var.cv_site_repo_id
  subject_claims    = ["pull_request"]
  policy_json       = local.cv_site_preview_policy
}
