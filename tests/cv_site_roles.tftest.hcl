mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
}

variables {
  # Forced by the Repository tag regex (docs/tagging-policy.md), not "any owner". These runs can't
  # tell a threaded var.github_owner from a hardcoded default; github_oidc_role.tftest.hcl covers that.
  # The GitHub owner/repo IDs are left at their real defaults (99756598, 1394684072, 1386380543), which
  # the subject assertions expect; a wrong or swapped ID fails, a hardcoded copy of the same value would not.
  github_owner = "goncalofileno"
  alert_email  = "alerts@example.com"
}

run "cv_site_roles_trust_only_the_expected_subjects" {
  command = apply

  assert {
    condition     = jsondecode(module.cv_site_deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:goncalofileno@99756598/cv-site@1386380543:ref:refs/heads/main"]
    error_message = "cv-site-deploy must only trust the cv-site main branch."
  }

  assert {
    condition     = jsondecode(module.cv_site_preview.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:goncalofileno@99756598/cv-site@1386380543:pull_request"]
    error_message = "cv-site-preview must only trust cv-site pull requests."
  }

  assert {
    condition     = jsondecode(module.cv_site_deploy.assume_role_policy).Statement[0].Principal.Federated == aws_iam_openid_connect_provider.github.arn
    error_message = "Roles must federate with the account's GitHub OIDC provider."
  }

  assert {
    condition     = jsondecode(module.cv_site_preview.assume_role_policy).Statement[0].Principal.Federated == aws_iam_openid_connect_provider.github.arn
    error_message = "cv-site-preview must also federate with the account's GitHub OIDC provider."
  }

  assert {
    condition     = aws_iam_openid_connect_provider.github.url == "https://token.actions.githubusercontent.com" && length(aws_iam_openid_connect_provider.github.client_id_list) == 1 && contains(aws_iam_openid_connect_provider.github.client_id_list, "sts.amazonaws.com")
    error_message = "OIDC provider must be GitHub Actions with audience sts.amazonaws.com."
  }
}

run "cv_site_deploy_cannot_escalate_privileges" {
  command = apply

  # Every statement that allows iam:CreateRole must require the cv-site boundary.
  assert {
    condition = alltrue([
      for s in jsondecode(module.cv_site_deploy.policy).Statement :
      !(s.Effect == "Allow" && contains(flatten([s.Action]), "iam:CreateRole")) ||
      try(s.Condition.StringEquals["iam:PermissionsBoundary"], "") == aws_iam_policy.cv_site_boundary.arn
    ])
    error_message = "iam:CreateRole must be conditioned on the cv-site-boundary permissions boundary."
  }

  # Broader guard: ANY Allow statement granting an iam:* / Create* / Put* / Attach*-style action
  # (not just the literal "iam:CreateRole") must require the boundary. Catches an added
  # {Effect=Allow, Action="iam:*", Resource="*"} statement, which the check above would miss.
  assert {
    condition = alltrue([
      for s in jsondecode(module.cv_site_deploy.policy).Statement :
      !(s.Effect == "Allow" && anytrue([
        for a in flatten([s.Action]) : can(regex("^iam:(\\*|Create.*|Put.*|Attach.*|.*\\*)$", a))
      ])) ||
      try(s.Condition.StringEquals["iam:PermissionsBoundary"], "") == aws_iam_policy.cv_site_boundary.arn
    ])
    error_message = "Every Allow statement granting iam:*/Create*/Put*/Attach*-style actions must require the cv-site-boundary permissions boundary."
  }

  assert {
    condition     = one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "PassSiteRolesToLambda"]).Condition.StringEquals["iam:PassedToService"] == "lambda.amazonaws.com"
    error_message = "iam:PassRole must be limited to the Lambda service."
  }

  # Broader guard: ANY Allow statement granting iam:PassRole (or an iam:* wildcard covering it),
  # not just the one named PassSiteRolesToLambda, must be scoped to the Lambda service. Catches
  # a second, unconditioned iam:PassRole statement added elsewhere in the policy.
  assert {
    condition = alltrue([
      for s in jsondecode(module.cv_site_deploy.policy).Statement :
      !(s.Effect == "Allow" && anytrue([for a in flatten([s.Action]) : a == "iam:PassRole" || a == "iam:*"])) ||
      try(s.Condition.StringEquals["iam:PassedToService"], "") == "lambda.amazonaws.com"
    ])
    error_message = "Every Allow statement granting iam:PassRole must be scoped to lambda.amazonaws.com via iam:PassedToService."
  }

  # Fail-closed guard: no deploy Allow action may be a bare "*" or have a wildcard in its
  # service prefix (e.g. an added {Effect=Allow, Action="*", Resource="*"} statement). The
  # iam:-anchored guards above would not catch this on their own since the action isn't
  # prefixed "iam:".
  assert {
    condition = alltrue([
      for a in flatten([for s in jsondecode(module.cv_site_deploy.policy).Statement : s.Action if s.Effect == "Allow"]) :
      !can(regex("^[^:]*\\*", a))
    ])
    error_message = "No deploy Allow action may be a bare wildcard or have a wildcard service prefix."
  }

  # Allow-list (not a pattern): every iam: action granted anywhere in the deploy policy must be
  # one of these. Catches an unlisted iam: action (e.g. an unconditioned iam:SetDefaultPolicyVersion
  # on Resource "*") that a pattern-based guard could miss.
  assert {
    condition = alltrue([
      for a in flatten([for s in jsondecode(module.cv_site_deploy.policy).Statement : s.Action if s.Effect == "Allow"]) :
      !startswith(a, "iam:") || contains([
        "iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:DeleteRolePolicy", "iam:PutRolePermissionsBoundary",
        "iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole", "iam:TagRole", "iam:UntagRole", "iam:UpdateRole", "iam:UpdateRoleDescription", "iam:UpdateAssumeRolePolicy", "iam:DeleteRole",
        "iam:PassRole",
        "iam:GetPolicy", "iam:GetPolicyVersion",
      ], a)
    ])
    error_message = "Deploy policy must only grant the explicit iam: allow-list; no unexpected iam: action."
  }

  assert {
    condition = (
      one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "DenyTouchingCiRoles"]).Effect == "Deny" &&
      one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "DenyTouchingCiRoles"]).Action == "iam:*" &&
      alltrue([
        for arn in ["arn:aws:iam::123456789012:role/cv-site-deploy", "arn:aws:iam::123456789012:role/cv-site-preview"] :
        contains(one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "DenyTouchingCiRoles"]).Resource, arn)
      ])
    )
    error_message = "The deploy role must deny all IAM actions (iam:*) on the CI roles themselves."
  }

  assert {
    condition = (
      one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "DenyChangingBoundaryPolicy"]).Effect == "Deny" &&
      toset(flatten([one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "DenyChangingBoundaryPolicy"]).Action])) == toset(["iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion"]) &&
      one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "DenyChangingBoundaryPolicy"]).Resource == aws_iam_policy.cv_site_boundary.arn
    )
    error_message = "The deploy role must be denied exactly the actions that could change the boundary policy, scoped to the boundary policy itself."
  }

  assert {
    condition = (
      one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "DenyRemovingBoundary"]).Effect == "Deny" &&
      contains(flatten([one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "DenyRemovingBoundary"]).Action]), "iam:DeleteRolePermissionsBoundary") &&
      one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "DenyRemovingBoundary"]).Resource == "arn:aws:iam::123456789012:role/cv-site-*"
    )
    error_message = "The deploy role must be denied removing the permissions boundary from cv-site-* roles."
  }

  assert {
    condition = (
      one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "DenyBaselineRoles"]).Effect == "Deny" &&
      one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "DenyBaselineRoles"]).Action == "iam:*" &&
      one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "DenyBaselineRoles"]).Resource == "arn:aws:iam::123456789012:role/baseline-*"
    )
    error_message = "The deploy role must deny all IAM actions (iam:*) on baseline-* roles."
  }

  # Allow-list (not a regex): exactly the eight SES actions the deploy role is granted today.
  # SES identity-policy / notification actions (e.g. ses:PutIdentityPolicy,
  # ses:SetIdentityNotificationTopic) grant sending authorization to other accounts or redirect
  # bounce/complaint notifications and must never show up here; neither should any SES wildcard.
  assert {
    condition = alltrue([
      for a in flatten([for s in jsondecode(module.cv_site_deploy.policy).Statement : s.Action if s.Effect == "Allow"]) :
      !startswith(a, "ses:") || contains([
        "ses:CreateEmailIdentity", "ses:DeleteEmailIdentity", "ses:GetEmailIdentity", "ses:PutEmailIdentityDkimAttributes",
        "ses:TagResource", "ses:UntagResource", "ses:ListTagsForResource", "ses:ListEmailIdentities",
      ], a)
    ])
    error_message = "Deploy policy must only grant the explicit SES allow-list."
  }

  # Allow-list (not a regex): exactly the lambda: actions the deploy role is granted today. No
  # lambda:* wildcard, no function-URL actions, no unlisted action of any kind.
  assert {
    condition = alltrue([
      for a in flatten([for s in jsondecode(module.cv_site_deploy.policy).Statement : s.Action if s.Effect == "Allow"]) :
      !startswith(a, "lambda:") || contains([
        "lambda:Get*", "lambda:List*", "lambda:CreateFunction", "lambda:DeleteFunction",
        "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration", "lambda:PublishVersion",
        "lambda:PutFunctionConcurrency", "lambda:TagResource", "lambda:UntagResource",
        "lambda:AddPermission", "lambda:RemovePermission",
      ], a)
    ])
    error_message = "Deploy policy must only grant the explicit lambda: allow-list."
  }

  # lambda:AddPermission/RemovePermission must only ever grant invoke access to API Gateway
  # (Pulumi's aws.lambda.Permission for API Gateway always uses this principal).
  assert {
    condition = (
      toset(flatten([one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "SiteFunctionPermissions"]).Action])) == toset(["lambda:AddPermission", "lambda:RemovePermission"]) &&
      one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "SiteFunctionPermissions"]).Condition.StringEquals["lambda:Principal"] == "apigateway.amazonaws.com"
    )
    error_message = "lambda:AddPermission/RemovePermission must be scoped to exactly those two actions with principal apigateway.amazonaws.com."
  }

  # s3:CreateBucket must stay in its own, unconditioned statement (aws:ResourceAccount can't be
  # evaluated against a bucket that doesn't exist yet) and grant nothing else.
  assert {
    condition = (
      toset(flatten([one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "CreateSiteBuckets"]).Action])) == toset(["s3:CreateBucket"]) &&
      !contains(keys(one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "CreateSiteBuckets"])), "Condition")
    )
    error_message = "s3:CreateBucket must be granted unconditionally, in a statement that grants only that action."
  }

  # The cv-site-* bucket ARN pattern is not account-scoped by itself; every S3 statement using
  # it must also require aws:ResourceAccount so it can't match another account's bucket.
  assert {
    condition     = try(one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "SiteBuckets"]).Condition.StringEquals["aws:ResourceAccount"], "") == "123456789012"
    error_message = "The deploy role's S3 bucket statement must be scoped to this account via aws:ResourceAccount."
  }

  assert {
    condition     = length(module.cv_site_deploy.policy) < 10240
    error_message = "Inline policy exceeds the 10,240-character IAM limit; merge statements that share a Resource."
  }
}

run "cv_site_boundary_allows_only_runtime_needs" {
  command = apply

  assert {
    condition = alltrue([
      for a in flatten([for s in jsondecode(aws_iam_policy.cv_site_boundary.policy).Statement : s.Action]) :
      contains([
        "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
        "ssm:GetParameter", "kms:Decrypt", "ses:SendEmail", "ses:SendRawEmail",
      ], a)
    ])
    error_message = "Boundary must only allow logs, ssm:GetParameter, kms:Decrypt (via SSM) and SES send."
  }

  assert {
    condition     = aws_iam_policy.cv_site_boundary.name == "cv-site-boundary"
    error_message = "Boundary policy must be named cv-site-boundary (the deploy policy relies on it)."
  }

  assert {
    condition = (
      one([for s in jsondecode(aws_iam_policy.cv_site_boundary.policy).Statement : s if s.Sid == "LambdaLogs"]).Resource == [
        "arn:aws:logs:eu-north-1:123456789012:log-group:/aws/lambda/cv-site-*",
        "arn:aws:logs:eu-north-1:123456789012:log-group:/aws/lambda/cv-site-*:*",
      ] &&
      one([for s in jsondecode(aws_iam_policy.cv_site_boundary.policy).Statement : s if s.Sid == "ReadOwnParameters"]).Resource == "arn:aws:ssm:eu-north-1:123456789012:parameter/cv-site/*" &&
      one([for s in jsondecode(aws_iam_policy.cv_site_boundary.policy).Statement : s if s.Sid == "SendEmail"]).Resource == "arn:aws:ses:eu-north-1:123456789012:identity/*"
    )
    error_message = "Boundary statements must be scoped to the exact expected resources."
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_policy.cv_site_boundary.policy).Statement : s if s.Sid == "DecryptParametersViaSsm"]).Condition.StringEquals["kms:ViaService"] == "ssm.eu-north-1.amazonaws.com"
    error_message = "kms:Decrypt in the boundary must be scoped to KMS calls made via SSM."
  }
}

run "cv_site_preview_is_read_only" {
  command = apply

  assert {
    condition = alltrue([
      for a in flatten([for s in jsondecode(module.cv_site_preview.policy).Statement : s.Action]) :
      can(regex("^[a-z0-9-]+:(Get|List|Describe)", a)) || a == "apigateway:GET"
    ])
    error_message = "cv-site-preview may only have Get/List/Describe actions."
  }

  assert {
    condition = (
      alltrue([for s in jsondecode(module.cv_site_preview.policy).Statement : s.Effect == "Allow"]) &&
      alltrue([
        for a in flatten([for s in jsondecode(module.cv_site_preview.policy).Statement : s.Action]) :
        !can(regex("^ssm:GetParameter", a)) && a != "secretsmanager:GetSecretValue"
      ])
    )
    error_message = "Preview must not read parameter or secret values."
  }

  assert {
    condition     = try(one([for s in jsondecode(module.cv_site_preview.policy).Statement : s if s.Sid == "S3ReadBucketConfig"]).Condition.StringEquals["aws:ResourceAccount"], "") == "123456789012"
    error_message = "Preview's S3 bucket statement must be scoped to this account via aws:ResourceAccount."
  }
}

# The allow-list/pattern asserts above catch specific escalation shapes, but none of them pin
# every statement's Resource. A mutation broadening ManageSiteRoles or PassSiteRolesToLambda to
# Resource = "*", or SiteBuckets to "arn:aws:s3:::*", passed every assert above. This run follows
# the exact ordered Sid list + exact per-Sid {Effect, Action, Resource, Condition} map pattern
# from tests/baseline_roles.tftest.hcl so every statement, not just the ones a targeted guard
# happens to name, is pinned.
run "cv_site_deploy_policy_matches_exactly" {
  command = apply

  # Fail-closed format guard: every deploy Allow action must be "<service>:<Word>", service one
  # of the ones this policy actually uses, and the action part letters/asterisks only (no digits,
  # no "?", case-sensitive). Catches a mutated action like "IAM:*" (wrong case) or "i?m:*"
  # (a wildcard-masked service prefix) that the bare-wildcard guard above does not check for.
  assert {
    condition = alltrue([
      for a in flatten([for s in jsondecode(module.cv_site_deploy.policy).Statement : s.Action if s.Effect == "Allow"]) :
      can(regex("^(s3|cloudfront|acm|lambda|apigateway|logs|ssm|kms|ses|iam):[A-Za-z*]+$", a))
    ])
    error_message = "Every deploy Allow action must match <known-service>:<Word-or-*>, case-sensitive, no digits or '?'."
  }

  # Exact, ordered statement list: catches any added, removed, renamed or reordered statement.
  assert {
    condition = [for s in jsondecode(module.cv_site_deploy.policy).Statement : s.Sid] == [
      "CreateSiteBuckets", "SiteBuckets", "CloudFront", "AcmForCloudFront", "SiteFunctions",
      "SiteFunctionPermissions", "HttpApis", "SiteLogGroups", "DescribeLogGroups", "SiteParameters",
      "DescribeParameters", "SsmKmsViaService", "SesIdentityManagement", "SesListIdentities",
      "CreateRolesOnlyWithBoundary", "ManageSiteRoles", "PassSiteRolesToLambda", "ReadBoundaryPolicy",
      "DenyTouchingCiRoles", "DenyRemovingBoundary", "DenyChangingBoundaryPolicy", "DenyBaselineRoles",
    ]
    error_message = "cv-site-deploy policy must declare exactly these statements, in this order."
  }

  # True allow-list: every statement's Effect/Action/Resource/Condition must match exactly.
  # Action and Resource are normalised with flatten([...]) so a single string and a one-element
  # list compare equal; Condition uses try(s.Condition, null) so a statement with no Condition
  # compares equal to a literal `null` on the expected side. A statement gaining or losing a
  # Condition, or a Resource broadened to "*"/a wider ARN pattern, fails this assert.
  assert {
    condition = {
      for s in jsondecode(module.cv_site_deploy.policy).Statement :
      s.Sid => { Effect = s.Effect, Action = flatten([s.Action]), Resource = flatten([s.Resource]), Condition = try(s.Condition, null) }
      } == {
      CreateSiteBuckets = {
        Effect    = "Allow", Action = ["s3:CreateBucket"]
        Resource  = ["arn:aws:s3:::cv-site-*", "arn:aws:s3:::cv-site-*/*"]
        Condition = null
      }
      SiteBuckets = {
        Effect    = "Allow", Action = ["s3:*"]
        Resource  = ["arn:aws:s3:::cv-site-*", "arn:aws:s3:::cv-site-*/*"]
        Condition = { StringEquals = { "aws:ResourceAccount" = "123456789012" } }
      }
      CloudFront = {
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
        Resource  = ["*"]
        Condition = null
      }
      AcmForCloudFront = {
        Effect    = "Allow"
        Action    = ["acm:RequestCertificate", "acm:DeleteCertificate", "acm:DescribeCertificate", "acm:GetCertificate", "acm:ListCertificates", "acm:ListTagsForCertificate", "acm:AddTagsToCertificate", "acm:RemoveTagsFromCertificate"]
        Resource  = ["*"]
        Condition = { StringEquals = { "aws:RequestedRegion" = "us-east-1" } }
      }
      SiteFunctions = {
        Effect = "Allow"
        Action = [
          "lambda:Get*", "lambda:List*", "lambda:CreateFunction", "lambda:DeleteFunction",
          "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration", "lambda:PublishVersion",
          "lambda:PutFunctionConcurrency", "lambda:TagResource", "lambda:UntagResource",
        ]
        Resource  = ["arn:aws:lambda:eu-north-1:123456789012:function:cv-site-*"]
        Condition = null
      }
      SiteFunctionPermissions = {
        Effect    = "Allow", Action = ["lambda:AddPermission", "lambda:RemovePermission"]
        Resource  = ["arn:aws:lambda:eu-north-1:123456789012:function:cv-site-*"]
        Condition = { StringEquals = { "lambda:Principal" = "apigateway.amazonaws.com" } }
      }
      HttpApis = {
        Effect    = "Allow", Action = ["apigateway:GET", "apigateway:POST", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE"]
        Resource  = ["arn:aws:apigateway:eu-north-1::/apis", "arn:aws:apigateway:eu-north-1::/apis/*", "arn:aws:apigateway:eu-north-1::/tags/*"]
        Condition = null
      }
      SiteLogGroups = {
        Effect    = "Allow"
        Action    = ["logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy", "logs:TagResource", "logs:UntagResource", "logs:ListTagsForResource", "logs:TagLogGroup", "logs:ListTagsLogGroup"]
        Resource  = ["arn:aws:logs:eu-north-1:123456789012:log-group:/aws/lambda/cv-site-*", "arn:aws:logs:eu-north-1:123456789012:log-group:/aws/lambda/cv-site-*:*"]
        Condition = null
      }
      DescribeLogGroups = { Effect = "Allow", Action = ["logs:DescribeLogGroups"], Resource = ["*"], Condition = null }
      SiteParameters = {
        Effect    = "Allow"
        Action    = ["ssm:PutParameter", "ssm:GetParameter", "ssm:GetParameters", "ssm:DeleteParameter", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource", "ssm:LabelParameterVersion"]
        Resource  = ["arn:aws:ssm:eu-north-1:123456789012:parameter/cv-site/*"]
        Condition = null
      }
      DescribeParameters = { Effect = "Allow", Action = ["ssm:DescribeParameters"], Resource = ["*"], Condition = null }
      SsmKmsViaService = {
        Effect    = "Allow", Action = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = ["*"]
        Condition = { StringEquals = { "kms:ViaService" = "ssm.eu-north-1.amazonaws.com" } }
      }
      SesIdentityManagement = {
        Effect    = "Allow"
        Action    = ["ses:CreateEmailIdentity", "ses:DeleteEmailIdentity", "ses:GetEmailIdentity", "ses:PutEmailIdentityDkimAttributes", "ses:TagResource", "ses:UntagResource", "ses:ListTagsForResource"]
        Resource  = ["arn:aws:ses:eu-north-1:123456789012:identity/*"]
        Condition = null
      }
      SesListIdentities = { Effect = "Allow", Action = ["ses:ListEmailIdentities"], Resource = ["*"], Condition = null }
      CreateRolesOnlyWithBoundary = {
        Effect    = "Allow"
        Action    = ["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:DeleteRolePolicy", "iam:PutRolePermissionsBoundary"]
        Resource  = ["arn:aws:iam::123456789012:role/cv-site-*"]
        Condition = { StringEquals = { "iam:PermissionsBoundary" = aws_iam_policy.cv_site_boundary.arn } }
      }
      ManageSiteRoles = {
        Effect    = "Allow"
        Action    = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole", "iam:TagRole", "iam:UntagRole", "iam:UpdateRole", "iam:UpdateRoleDescription", "iam:UpdateAssumeRolePolicy", "iam:DeleteRole"]
        Resource  = ["arn:aws:iam::123456789012:role/cv-site-*"]
        Condition = null
      }
      PassSiteRolesToLambda = {
        Effect    = "Allow", Action = ["iam:PassRole"]
        Resource  = ["arn:aws:iam::123456789012:role/cv-site-*"]
        Condition = { StringEquals = { "iam:PassedToService" = "lambda.amazonaws.com" } }
      }
      ReadBoundaryPolicy = {
        Effect    = "Allow", Action = ["iam:GetPolicy", "iam:GetPolicyVersion"]
        Resource  = [aws_iam_policy.cv_site_boundary.arn]
        Condition = null
      }
      DenyTouchingCiRoles = {
        Effect = "Deny", Action = ["iam:*"]
        Resource = [
          "arn:aws:iam::123456789012:role/cv-site-deploy",
          "arn:aws:iam::123456789012:role/cv-site-preview",
        ]
        Condition = null
      }
      DenyRemovingBoundary = {
        Effect    = "Deny", Action = ["iam:DeleteRolePermissionsBoundary"]
        Resource  = ["arn:aws:iam::123456789012:role/cv-site-*"]
        Condition = null
      }
      DenyChangingBoundaryPolicy = {
        Effect    = "Deny"
        Action    = ["iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion"]
        Resource  = [aws_iam_policy.cv_site_boundary.arn]
        Condition = null
      }
      DenyBaselineRoles = {
        Effect    = "Deny", Action = ["iam:*"]
        Resource  = ["arn:aws:iam::123456789012:role/baseline-*"]
        Condition = null
      }
    }
    error_message = "cv-site-deploy policy statements must match exactly (Effect, Action, Resource, Condition) — no broadening, no extra actions or resources on any statement."
  }
}

run "cv_site_preview_policy_matches_exactly" {
  command = apply

  # Exact, ordered statement list: catches any added, removed, renamed or reordered statement
  # (e.g. a smuggled-in write action hidden behind a new Sid).
  assert {
    condition = [for s in jsondecode(module.cv_site_preview.policy).Statement : s.Sid] == [
      "S3ReadBucketConfig", "CloudFrontRead", "AcmRead", "LambdaRead", "ApiRead", "LogsRead", "SsmMetadataRead", "SesRead", "IamRead",
    ]
    error_message = "cv-site-preview policy must declare exactly these statements, in this order."
  }

  # True allow-list: every statement's Effect/Action/Resource/Condition must match exactly.
  assert {
    condition = {
      for s in jsondecode(module.cv_site_preview.policy).Statement :
      s.Sid => { Effect = s.Effect, Action = flatten([s.Action]), Resource = flatten([s.Resource]), Condition = try(s.Condition, null) }
      } == {
      S3ReadBucketConfig = {
        Effect    = "Allow"
        Action    = ["s3:GetBucket*", "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration", "s3:GetAccelerateConfiguration", "s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource  = ["arn:aws:s3:::cv-site-*"]
        Condition = { StringEquals = { "aws:ResourceAccount" = "123456789012" } }
      }
      CloudFrontRead = { Effect = "Allow", Action = ["cloudfront:Get*", "cloudfront:List*", "cloudfront:DescribeFunction"], Resource = ["*"], Condition = null }
      AcmRead        = { Effect = "Allow", Action = ["acm:DescribeCertificate", "acm:ListCertificates", "acm:ListTagsForCertificate"], Resource = ["*"], Condition = null }
      LambdaRead = {
        Effect    = "Allow", Action = ["lambda:Get*", "lambda:List*"]
        Resource  = ["arn:aws:lambda:eu-north-1:123456789012:function:cv-site-*"]
        Condition = null
      }
      ApiRead = {
        Effect    = "Allow", Action = ["apigateway:GET"]
        Resource  = ["arn:aws:apigateway:eu-north-1::/apis", "arn:aws:apigateway:eu-north-1::/apis/*", "arn:aws:apigateway:eu-north-1::/tags/*"]
        Condition = null
      }
      LogsRead        = { Effect = "Allow", Action = ["logs:DescribeLogGroups", "logs:ListTagsForResource", "logs:ListTagsLogGroup"], Resource = ["*"], Condition = null }
      SsmMetadataRead = { Effect = "Allow", Action = ["ssm:DescribeParameters", "ssm:ListTagsForResource"], Resource = ["*"], Condition = null }
      SesRead         = { Effect = "Allow", Action = ["ses:Get*", "ses:List*"], Resource = ["*"], Condition = null }
      IamRead = {
        Effect    = "Allow", Action = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"]
        Resource  = ["arn:aws:iam::123456789012:role/cv-site-*"]
        Condition = null
      }
    }
    error_message = "cv-site-preview policy statements must match exactly (Effect, Action, Resource, Condition) — no broadening, no extra actions or resources on any statement."
  }
}
