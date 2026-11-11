mock_provider "aws" {
  # Valid ARNs for resources whose ARN feeds an ARN-validated argument (kill-switch.tf, budget.tf).
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock"
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:eu-north-1:123456789012:mock"
    }
  }

  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:eu-north-1:123456789012:function:mock"
    }
  }

  # The subscription validates monitor_arn_list as ARNs; OpenTofu's plan rejects a random mock string.
  mock_resource "aws_ce_anomaly_monitor" {
    defaults = {
      arn = "arn:aws:ce::123456789012:anomalymonitor/00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  # Forced by the Repository tag regex (docs/tagging-policy.md), not "any owner". These runs can't
  # tell a threaded var.github_owner from a hardcoded default; github_oidc_role.tftest.hcl covers that.
  github_owner = "goncalofileno"
  alert_email  = "alerts@example.com"
}

run "all_four_flags_are_on" {
  command = apply

  assert {
    condition = (
      aws_s3_account_public_access_block.this.block_public_acls == true &&
      aws_s3_account_public_access_block.this.block_public_policy == true &&
      aws_s3_account_public_access_block.this.ignore_public_acls == true &&
      aws_s3_account_public_access_block.this.restrict_public_buckets == true
    )
    error_message = "The account-level S3 public access block must have all four flags on."
  }
}
