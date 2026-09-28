mock_provider "aws" {}

variables {
  # Forced by the Repository tag regex (docs/tagging-policy.md), not "any owner". These runs can't
  # tell a threaded var.github_owner from a hardcoded default; github_oidc_role.tftest.hcl covers that.
  github_owner = "goncalofileno"
  alert_email  = "alerts@example.com"
}

run "accepts_valid_inputs" {
  command = plan
}

run "rejects_github_owner_with_spaces" {
  command = plan

  variables {
    github_owner = "bad owner"
  }

  expect_failures = [var.github_owner]
}

run "rejects_invalid_alert_email" {
  command = plan

  variables {
    alert_email = "not-an-email"
  }

  expect_failures = [var.alert_email]
}

run "rejects_region_outside_scp_allow_list" {
  command = plan

  variables {
    region = "ap-southeast-1"
  }

  expect_failures = [var.region]
}

run "root_tags_are_exact" {
  command = plan

  assert {
    condition = module.tags.tags == {
      Project     = "cv-site"
      Component   = "account-baseline"
      Environment = "shared"
      ManagedBy   = "terraform"
      Repository  = "github.com/goncalofileno/aws-account-baseline"
      Owner       = "goncalo-fileno"
    }
    error_message = "Root module must tag every resource with exactly this map via default_tags."
  }
}
