mock_provider "aws" {}

variables {
  github_owner = "test-owner"
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
