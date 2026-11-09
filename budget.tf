resource "aws_budgets_budget" "monthly_cost" {
  name         = "monthly-cost"
  budget_type  = "COST"
  limit_amount = "5.0" # AWS normalises to one decimal; "5" would cause a perpetual diff
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 40
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # Cost kill switch (kill-switch.tf): the actual bill catches any cause the metrics estimate misses.
  # Each threshold fires once a month, so the second one still covers a month after a rearm.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 200
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.kill_switch_trigger.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 400
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.kill_switch_trigger.arn]
  }

  # Budgets checks that it may publish when the notification is created.
  depends_on = [aws_sns_topic_policy.kill_switch_trigger]
}
