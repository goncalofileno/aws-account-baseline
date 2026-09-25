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

  assert {
    condition     = one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "PassSiteRolesToLambda"]).Condition.StringEquals["iam:PassedToService"] == "lambda.amazonaws.com"
    error_message = "iam:PassRole must be limited to the Lambda service."
  }

  assert {
    condition = alltrue([
      for arn in ["arn:aws:iam::123456789012:role/cv-site-deploy", "arn:aws:iam::123456789012:role/cv-site-preview"] :
      contains(one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "DenyTouchingCiRoles"]).Resource, arn)
    ])
    error_message = "The deploy role must be denied IAM actions on the CI roles themselves."
  }

  assert {
    condition     = one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "DenyChangingBoundaryPolicy"]).Effect == "Deny"
    error_message = "The deploy role must be denied changes to the boundary policy."
  }

  assert {
    condition     = one([for s in jsondecode(module.cv_site_deploy.policy).Statement : s if s.Sid == "DenyBaselineRoles"]).Resource == "arn:aws:iam::123456789012:role/baseline-*"
    error_message = "The deploy role must be denied IAM actions on baseline-* roles."
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
    condition     = alltrue([for s in jsondecode(module.cv_site_preview.policy).Statement : s.Effect == "Allow"]) && !contains(flatten([for s in jsondecode(module.cv_site_preview.policy).Statement : s.Action]), "ssm:GetParameter")
    error_message = "Preview must not read parameter values (secrets)."
  }
}
