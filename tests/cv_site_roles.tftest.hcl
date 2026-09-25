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

  # SES identity-policy actions (PutIdentityPolicy, SetIdentityNotificationTopic, etc.) grant
  # sending authorization to other accounts and must never be in the deploy role. No SES
  # wildcard actions either.
  assert {
    condition = alltrue([
      for a in flatten([for s in jsondecode(module.cv_site_deploy.policy).Statement : s.Action]) :
      !can(regex("(?i)^ses:.*(policy|policies)", a)) && !can(regex("^ses:.*\\*", a))
    ])
    error_message = "The deploy role must not manage SES sending-authorization policies or use SES wildcard actions."
  }

  # Lambda must be enumerated explicitly: no wildcard writes, and no function-URL or
  # concurrency-deletion actions (both are extra attack surface not needed by the site).
  assert {
    condition = alltrue([
      for a in flatten([for s in jsondecode(module.cv_site_deploy.policy).Statement : s.Action]) :
      a != "lambda:*" && a != "lambda:CreateFunctionUrlConfig" && a != "lambda:UpdateFunctionUrlConfig" && a != "lambda:DeleteFunctionConcurrency"
    ])
    error_message = "The deploy role must not have a lambda:* wildcard or manage function URLs/concurrency deletion."
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
