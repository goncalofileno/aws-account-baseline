mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
}

variables {
  github_owner = "test-owner"
}

run "cv_site_roles_trust_only_the_expected_subjects" {
  command = apply

  assert {
    condition     = jsondecode(module.cv_site_deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:test-owner/cv-site:ref:refs/heads/main"]
    error_message = "cv-site-deploy must only trust the cv-site main branch."
  }

  assert {
    condition     = jsondecode(module.cv_site_preview.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:test-owner/cv-site:pull_request"]
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
        "arn:aws:logs:eu-west-1:123456789012:log-group:/aws/lambda/cv-site-*",
        "arn:aws:logs:eu-west-1:123456789012:log-group:/aws/lambda/cv-site-*:*",
      ] &&
      one([for s in jsondecode(aws_iam_policy.cv_site_boundary.policy).Statement : s if s.Sid == "ReadOwnParameters"]).Resource == "arn:aws:ssm:eu-west-1:123456789012:parameter/cv-site/*" &&
      one([for s in jsondecode(aws_iam_policy.cv_site_boundary.policy).Statement : s if s.Sid == "SendEmail"]).Resource == "arn:aws:ses:eu-west-1:123456789012:identity/*"
    )
    error_message = "Boundary statements must be scoped to the exact expected resources."
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_policy.cv_site_boundary.policy).Statement : s if s.Sid == "DecryptParametersViaSsm"]).Condition.StringEquals["kms:ViaService"] == "ssm.eu-west-1.amazonaws.com"
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
