mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
}

run "state_bucket_is_named_after_the_account" {
  command = apply

  assert {
    condition     = output.state_bucket == "gf-tfstate-123456789012"
    error_message = "State bucket must be named gf-tfstate-<account-id>."
  }
}

run "rejects_region_outside_scp_allow_list" {
  command = plan

  variables {
    region = "ap-southeast-1"
  }

  expect_failures = [var.region]
}
