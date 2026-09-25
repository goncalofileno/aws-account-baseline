mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
}

variables {
  github_owner = "test-owner"
  alert_email  = "alerts@example.com"
}

run "budget_caps_spend_at_five_dollars" {
  command = apply

  assert {
    condition     = aws_budgets_budget.monthly_cost.limit_amount == "5.0" && aws_budgets_budget.monthly_cost.limit_unit == "USD" && aws_budgets_budget.monthly_cost.time_unit == "MONTHLY" && aws_budgets_budget.monthly_cost.budget_type == "COST"
    error_message = "Budget must be a USD 5.0 monthly cost budget."
  }

  assert {
    condition     = length(aws_budgets_budget.monthly_cost.notification) == 2
    error_message = "Budget must have exactly two notifications."
  }

  assert {
    condition     = anytrue([for n in aws_budgets_budget.monthly_cost.notification : n.notification_type == "FORECASTED" && n.threshold == 40 && n.threshold_type == "PERCENTAGE"])
    error_message = "Budget must alert when forecasted spend exceeds 40 % (USD 2)."
  }

  assert {
    condition     = anytrue([for n in aws_budgets_budget.monthly_cost.notification : n.notification_type == "ACTUAL" && n.threshold == 100 && n.threshold_type == "PERCENTAGE"])
    error_message = "Budget must alert when actual spend exceeds 100 % (USD 5)."
  }
}

run "cloudtrail_is_multi_region_with_validation" {
  command = apply

  assert {
    condition     = aws_cloudtrail.main.name == "baseline-management-events"
    error_message = "Trail must be named baseline-management-events (the apply role is scoped to it)."
  }

  assert {
    condition     = aws_cloudtrail.main.is_multi_region_trail && aws_cloudtrail.main.include_global_service_events && aws_cloudtrail.main.enable_log_file_validation
    error_message = "Trail must be multi-region, include global events and validate log files."
  }

  assert {
    condition     = aws_cloudtrail.main.s3_bucket_name == "gf-cloudtrail-123456789012"
    error_message = "Trail must deliver to gf-cloudtrail-<account-id>."
  }

  assert {
    condition     = output.cloudtrail_bucket == "gf-cloudtrail-123456789012"
    error_message = "cloudtrail_bucket output must be the trail bucket name."
  }

  # The module's own resources (e.g. aws_s3_bucket_policy.this) aren't addressable from a
  # root-module test run, so this asserts on the exact statements handed to the module's
  # extra_policy_statements input instead: only CloudTrail may write, only to its own prefix,
  # and only when acting as this account's trail (aws:SourceArn). Catches a broadened
  # Principal, an unscoped Resource (e.g. the whole bucket) or a missing SourceArn condition.
  assert {
    condition = local.cloudtrail_bucket_statements == [
      {
        Sid       = "CloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = "arn:aws:s3:::gf-cloudtrail-123456789012"
        Condition = { StringEquals = { "aws:SourceArn" = "arn:aws:cloudtrail:eu-west-1:123456789012:trail/baseline-management-events" } }
      },
      {
        Sid       = "CloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "arn:aws:s3:::gf-cloudtrail-123456789012/AWSLogs/123456789012/*"
        Condition = { StringEquals = { "aws:SourceArn" = "arn:aws:cloudtrail:eu-west-1:123456789012:trail/baseline-management-events" } }
      },
    ]
    error_message = "The trail bucket must grant exactly these two CloudTrail-only statements (principal, action and resource), each scoped to this trail via aws:SourceArn."
  }
}
