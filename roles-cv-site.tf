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
      { Sid = "HttpApis", Effect = "Allow", Action = ["apigateway:GET", "apigateway:POST", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE"], Resource = local.cv_site_apis },
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
