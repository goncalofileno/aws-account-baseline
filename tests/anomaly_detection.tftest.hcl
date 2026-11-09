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

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  # The subscription validates monitor_arn_list as ARNs; a random mock string is rejected.
  mock_resource "aws_ce_anomaly_monitor" {
    defaults = {
      arn = "arn:aws:ce::123456789012:anomalymonitor/00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  # Forced by the Repository tag regex (docs/tagging-policy.md), not "any owner".
  github_owner = "goncalofileno"
  alert_email  = "alerts@example.com"
}

run "services_monitor_watches_every_aws_service" {
  command = apply

  assert {
    condition     = aws_ce_anomaly_monitor.services.monitor_type == "DIMENSIONAL" && aws_ce_anomaly_monitor.services.monitor_dimension == "SERVICE"
    error_message = "The monitor must be the dimensional SERVICE monitor (AWS-managed 'AWS services' monitor, one per account)."
  }

  assert {
    condition     = aws_ce_anomaly_monitor.services.name == "aws-services"
    error_message = "The monitor must be named aws-services."
  }
}

run "subscription_emails_a_daily_digest_above_one_dollar" {
  command = apply

  assert {
    condition     = aws_ce_anomaly_subscription.daily_email.frequency == "DAILY"
    error_message = "Alerts must be a DAILY digest (EMAIL subscribers only support DAILY or WEEKLY)."
  }

  assert {
    condition     = aws_ce_anomaly_subscription.daily_email.monitor_arn_list == tolist([aws_ce_anomaly_monitor.services.arn])
    error_message = "The subscription must cover exactly the services monitor."
  }

  # Exactly one subscriber: the alert address variable, by email.
  assert {
    condition = (
      length(aws_ce_anomaly_subscription.daily_email.subscriber) == 1 &&
      one(aws_ce_anomaly_subscription.daily_email.subscriber).type == "EMAIL" &&
      one(aws_ce_anomaly_subscription.daily_email.subscriber).address == var.alert_email
    )
    error_message = "The only subscriber must be var.alert_email, by EMAIL."
  }

  # Exact threshold: total impact >= USD 1, and nothing else (no AND/OR/percentage branches).
  assert {
    condition = (
      length(aws_ce_anomaly_subscription.daily_email.threshold_expression) == 1 &&
      length(one(aws_ce_anomaly_subscription.daily_email.threshold_expression).and) == 0 &&
      length(one(aws_ce_anomaly_subscription.daily_email.threshold_expression).or) == 0 &&
      length(one(aws_ce_anomaly_subscription.daily_email.threshold_expression).not) == 0 &&
      one(one(aws_ce_anomaly_subscription.daily_email.threshold_expression).dimension).key == "ANOMALY_TOTAL_IMPACT_ABSOLUTE" &&
      one(one(aws_ce_anomaly_subscription.daily_email.threshold_expression).dimension).match_options == toset(["GREATER_THAN_OR_EQUAL"]) &&
      one(one(aws_ce_anomaly_subscription.daily_email.threshold_expression).dimension).values == toset(["1"])
    )
    error_message = "The subscription must alert when ANOMALY_TOTAL_IMPACT_ABSOLUTE >= 1 (USD), with no other conditions."
  }
}
