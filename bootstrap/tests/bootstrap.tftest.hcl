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

run "bootstrap_tags_are_exact" {
  command = plan

  assert {
    condition = module.tags.tags == {
      Project     = "cv-site"
      Component   = "tf-state"
      Environment = "shared"
      ManagedBy   = "terraform"
      Repository  = "github.com/goncalofileno/aws-account-baseline"
      Owner       = "goncalo-fileno"
    }
    error_message = "Bootstrap must tag its state bucket with exactly this map via default_tags."
  }
}
