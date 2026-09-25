mock_provider "aws" {}

variables {
  github_owner = "test-owner"
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
