# AWS Cost Anomaly Detection: free, and complements the budget in budget.tf. The budget catches
# a month that is going over USD 5; this catches a sudden spike in any one service within a day,
# long before it moves the monthly total.
#
# DIMENSIONAL + SERVICE is the AWS-managed "AWS services" monitor. AWS allows only one per account
# (Billing and Cost Management quotas), so a second one, created by hand or by another tool, would
# make this apply fail: check `aws ce get-anomaly-monitors --region us-east-1` first.
resource "aws_ce_anomaly_monitor" "services" {
  name              = "aws-services"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "daily_email" {
  name             = "aws-services-daily"
  frequency        = "DAILY" # EMAIL subscribers support DAILY or WEEKLY only (IMMEDIATE needs SNS)
  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "EMAIL"
    address = var.alert_email
  }

  # Alert on any anomaly whose total cost impact is at least USD 1: the whole account is meant to
  # cost about USD 0/month, so even a small spike is worth an email.
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = ["1"]
    }
  }
}
