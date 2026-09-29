mock_provider "aws" {}

run "trust_policy_pins_audience_and_full_subjects" {
  command = apply

  module {
    source = "./modules/github-oidc-role"
  }

  variables {
    name              = "test-role"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    github_owner      = "test-owner"
    github_owner_id   = 11111
    github_repo       = "test-repo"
    github_repo_id    = 22222
    subject_claims    = ["ref:refs/heads/main", "pull_request"]
    policy_json       = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }

  assert {
    condition     = jsondecode(output.assume_role_policy).Statement[0].Principal.Federated == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    error_message = "Trust policy must federate with the given OIDC provider."
  }

  assert {
    condition     = jsondecode(output.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity"
    error_message = "Trust policy must only allow AssumeRoleWithWebIdentity."
  }

  assert {
    condition     = jsondecode(output.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    error_message = "Trust policy must pin the audience to sts.amazonaws.com."
  }

  assert {
    condition = jsondecode(output.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == [
      "repo:test-owner@11111/test-repo@22222:ref:refs/heads/main",
      "repo:test-owner@11111/test-repo@22222:pull_request",
    ]
    error_message = "Trust policy must list the full, exact subjects."
  }

  assert {
    condition     = aws_iam_role.this.permissions_boundary == null
    error_message = "No permissions boundary unless one is given."
  }

  assert {
    condition     = aws_iam_role_policy.this.policy == "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    error_message = "Inline policy must be exactly policy_json."
  }
}

run "attaches_permissions_boundary_when_given" {
  command = apply

  module {
    source = "./modules/github-oidc-role"
  }

  variables {
    name                     = "test-role"
    oidc_provider_arn        = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    github_owner             = "test-owner"
    github_owner_id          = 11111
    github_repo              = "test-repo"
    github_repo_id           = 22222
    subject_claims           = ["pull_request"]
    policy_json              = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    permissions_boundary_arn = "arn:aws:iam::123456789012:policy/test-boundary"
  }

  assert {
    condition     = aws_iam_role.this.permissions_boundary == "arn:aws:iam::123456789012:policy/test-boundary"
    error_message = "Permissions boundary must be attached when provided."
  }
}

run "rejects_wildcard_subjects" {
  command = plan

  module {
    source = "./modules/github-oidc-role"
  }

  variables {
    name              = "test-role"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    github_owner      = "test-owner"
    github_owner_id   = 11111
    github_repo       = "test-repo"
    github_repo_id    = 22222
    subject_claims    = ["ref:refs/heads/*"]
    policy_json       = "{}"
  }

  expect_failures = [var.subject_claims]
}

run "rejects_empty_subjects" {
  command = plan

  module {
    source = "./modules/github-oidc-role"
  }

  variables {
    name              = "test-role"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    github_owner      = "test-owner"
    github_owner_id   = 11111
    github_repo       = "test-repo"
    github_repo_id    = 22222
    subject_claims    = []
    policy_json       = "{}"
  }

  expect_failures = [var.subject_claims]
}

run "rejects_non_positive_owner_id" {
  command = plan

  module {
    source = "./modules/github-oidc-role"
  }

  variables {
    name              = "test-role"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    github_owner      = "test-owner"
    github_owner_id   = 0
    github_repo       = "test-repo"
    github_repo_id    = 22222
    subject_claims    = ["pull_request"]
    policy_json       = "{}"
  }

  expect_failures = [var.github_owner_id]
}

run "rejects_negative_owner_id" {
  command = plan

  module {
    source = "./modules/github-oidc-role"
  }

  variables {
    name              = "test-role"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    github_owner      = "test-owner"
    github_owner_id   = -5
    github_repo       = "test-repo"
    github_repo_id    = 22222
    subject_claims    = ["pull_request"]
    policy_json       = "{}"
  }

  expect_failures = [var.github_owner_id]
}

run "rejects_fractional_owner_id" {
  command = plan

  module {
    source = "./modules/github-oidc-role"
  }

  variables {
    name              = "test-role"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    github_owner      = "test-owner"
    github_owner_id   = 1.5
    github_repo       = "test-repo"
    github_repo_id    = 22222
    subject_claims    = ["pull_request"]
    policy_json       = "{}"
  }

  expect_failures = [var.github_owner_id]
}

run "rejects_non_positive_repo_id" {
  command = plan

  module {
    source = "./modules/github-oidc-role"
  }

  variables {
    name              = "test-role"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    github_owner      = "test-owner"
    github_owner_id   = 11111
    github_repo       = "test-repo"
    github_repo_id    = 0
    subject_claims    = ["pull_request"]
    policy_json       = "{}"
  }

  expect_failures = [var.github_repo_id]
}

run "rejects_negative_repo_id" {
  command = plan

  module {
    source = "./modules/github-oidc-role"
  }

  variables {
    name              = "test-role"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    github_owner      = "test-owner"
    github_owner_id   = 11111
    github_repo       = "test-repo"
    github_repo_id    = -5
    subject_claims    = ["pull_request"]
    policy_json       = "{}"
  }

  expect_failures = [var.github_repo_id]
}

run "rejects_fractional_repo_id" {
  command = plan

  module {
    source = "./modules/github-oidc-role"
  }

  variables {
    name              = "test-role"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    github_owner      = "test-owner"
    github_owner_id   = 11111
    github_repo       = "test-repo"
    github_repo_id    = 1.5
    subject_claims    = ["pull_request"]
    policy_json       = "{}"
  }

  expect_failures = [var.github_repo_id]
}
