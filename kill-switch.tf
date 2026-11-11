# Cost kill switch. Design: docs/specs/2026-11-09-cost-kill-switch-design.md.
#
# A Lambda runs every minute, estimates this month's spend from CloudWatch metrics and, above the
# threshold (or when the budget publishes to the trigger topic), disables every CloudFront
# distribution, turns off every HTTP API's default endpoint and zeroes every other Lambda's
# reserved concurrency. Resource counts above the kill_switch_max_* limits trip it too. Only the kill-switch
# workflow (environment kill-switch) brings the site back. ARN locals live in roles-baseline.tf.

locals {
  kill_switch_threshold_usd = 5
  kill_switch_alerts_arn    = "arn:aws:sns:${var.region}:${local.account_id}:cost-kill-switch-alerts"
  # Exactly the document state.py's tests pin as TERRAFORM_INITIAL: jsonencode sorts the keys. The
  # month is in the past on purpose: the first run rolls it over to the current month.
  kill_switch_initial_state = jsonencode({
    status                 = "armed"
    month                  = "1970-01"
    acknowledged_usd       = 0
    tripped_at             = null
    reason                 = null
    estimate_usd           = null
    disabled_distributions = []
    disabled_apis          = []
    concurrency            = {}
  })
}

data "archive_file" "kill_switch" {
  type        = "zip"
  source_dir  = "${path.module}/functions/cost_kill_switch/src"
  excludes    = ["**/__pycache__/**"]
  output_path = "${path.module}/.build/cost-kill-switch.zip"
  # Fixed modes so source_code_hash doesn't depend on the local umask.
  output_file_mode = "0644"
}

resource "aws_cloudwatch_log_group" "kill_switch" {
  #checkov:skip=CKV_AWS_158:Logs hold estimates and decisions only; a customer KMS key costs USD 1 a month
  #checkov:skip=CKV_AWS_338:30 days is enough for a one-line-per-minute decision log
  name              = "/aws/lambda/cost-kill-switch"
  retention_in_days = 30
}

resource "aws_iam_role" "kill_switch" {
  name        = "baseline-cost-kill-switch"
  description = "Execution role of the cost kill switch Lambda."
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
      # No aws:SourceAccount: Lambda execution roles don't take it; only Lambda in this account can use the role (iam:PassRole).
    }]
  })
}

resource "aws_iam_role_policy" "kill_switch" {
  name = "baseline-cost-kill-switch-policy"
  role = aws_iam_role.kill_switch.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # GetMetricStatistics, ListDistributions and ListFunctions take no resource type.
      { Sid = "ReadMetrics", Effect = "Allow", Action = ["cloudwatch:GetMetricStatistics"], Resource = "*" },
      { Sid = "ListDistributions", Effect = "Allow", Action = ["cloudfront:ListDistributions"], Resource = "*" },
      { Sid = "SwitchDistributions", Effect = "Allow", Action = ["cloudfront:GetDistributionConfig", "cloudfront:UpdateDistribution"], Resource = "arn:aws:cloudfront::${local.account_id}:distribution/*" },
      { Sid = "ListApis", Effect = "Allow", Action = ["apigateway:GET"], Resource = "arn:aws:apigateway:${var.region}::/apis" },
      # UpdateApi (PATCH) sets DisableExecuteApiEndpoint on a trip; GET on a single API isn't granted.
      { Sid = "SwitchApiEndpoints", Effect = "Allow", Action = ["apigateway:PATCH"], Resource = "arn:aws:apigateway:${var.region}::/apis/*" },
      { Sid = "ListFunctions", Effect = "Allow", Action = ["lambda:ListFunctions"], Resource = "*" },
      { Sid = "FunctionConcurrency", Effect = "Allow", Action = ["lambda:GetFunctionConcurrency", "lambda:PutFunctionConcurrency", "lambda:DeleteFunctionConcurrency"], Resource = "arn:aws:lambda:${var.region}:${local.account_id}:function:*" },
      { Sid = "NotItself", Effect = "Deny", Action = ["lambda:PutFunctionConcurrency", "lambda:DeleteFunctionConcurrency"], Resource = local.kill_switch_function_arn },
      { Sid = "State", Effect = "Allow", Action = ["ssm:GetParameter", "ssm:PutParameter"], Resource = local.kill_switch_parameter_arn },
      { Sid = "Alerts", Effect = "Allow", Action = ["sns:Publish"], Resource = local.kill_switch_alerts_arn },
      { Sid = "Logs", Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${local.kill_switch_log_groups[0]}:*" },
    ]
  })
}

resource "aws_lambda_function" "kill_switch" {
  #checkov:skip=CKV_AWS_117:Calls only AWS APIs; a VPC would add NAT or endpoint costs
  #checkov:skip=CKV_AWS_116:Invoked every minute; the next run is the retry, and the errors alarm reports failures
  #checkov:skip=CKV_AWS_272:Code is deployed only by this repo's reviewed apply
  #checkov:skip=CKV_AWS_173:Environment holds names and ARNs only, no secrets
  #checkov:skip=CKV_AWS_50:X-Ray adds cost and nothing the decision log doesn't show
  function_name                  = "cost-kill-switch"
  description                    = "Takes the site offline when this month's estimated spend passes the threshold."
  role                           = aws_iam_role.kill_switch.arn
  runtime                        = "python3.13"
  handler                        = "handler.lambda_handler"
  filename                       = data.archive_file.kill_switch.output_path
  source_code_hash               = data.archive_file.kill_switch.output_base64sha256
  memory_size                    = 128
  timeout                        = 60
  reserved_concurrent_executions = 1

  environment {
    variables = {
      STATE_PARAMETER   = aws_ssm_parameter.kill_switch_state.name
      ALERTS_TOPIC_ARN  = aws_sns_topic.kill_switch_alerts.arn
      TRIGGER_TOPIC_ARN = aws_sns_topic.kill_switch_trigger.arn
      THRESHOLD_USD     = tostring(local.kill_switch_threshold_usd)
      # format("%d") keeps 1e12 a plain decimal string, which the Lambda parses as an integer.
      MAX_DISTRIBUTIONS        = format("%d", var.kill_switch_max_distributions)
      MAX_APIS                 = format("%d", var.kill_switch_max_apis)
      MAX_FUNCTIONS            = format("%d", var.kill_switch_max_functions)
      FREE_CLOUDFRONT_BYTES    = format("%d", var.kill_switch_free_cloudfront_bytes)
      FREE_CLOUDFRONT_REQUESTS = format("%d", var.kill_switch_free_cloudfront_requests)
    }
  }

  depends_on = [aws_cloudwatch_log_group.kill_switch, aws_iam_role_policy.kill_switch]
}

resource "aws_ssm_parameter" "kill_switch_state" {
  #checkov:skip=CKV2_AWS_34:The state is not secret, and cv-site-deploy reads it without KMS
  name        = "/cost-kill-switch/state"
  description = "Cost kill switch state. Owned by the Lambda after creation."
  type        = "String"
  value       = local.kill_switch_initial_state

  lifecycle {
    # The Lambda owns the value; Terraform only creates it.
    ignore_changes = [value]
  }
}

# --- Every minute

resource "aws_iam_role" "kill_switch_scheduler" {
  name        = "baseline-kill-switch-scheduler"
  description = "Lets EventBridge Scheduler invoke the cost kill switch."
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "kill_switch_scheduler" {
  name = "baseline-kill-switch-scheduler-policy"
  role = aws_iam_role.kill_switch_scheduler.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Sid = "InvokeKillSwitch", Effect = "Allow", Action = "lambda:InvokeFunction", Resource = local.kill_switch_function_arn }]
  })
}

resource "aws_scheduler_schedule" "kill_switch_check" {
  #checkov:skip=CKV_AWS_297:The input is {"action":"check"} and holds no secrets; a customer KMS key costs USD 1 a month
  name                = "cost-kill-switch-check"
  description         = "Runs the cost kill switch check every minute."
  schedule_expression = "rate(1 minute)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.kill_switch.arn
    role_arn = aws_iam_role.kill_switch_scheduler.arn
    input    = jsonencode({ action = "check" })

    retry_policy {
      maximum_retry_attempts       = 0 # the next minute is the retry (the Lambda's own 2 async retries still apply, which is fine)
      maximum_event_age_in_seconds = 60
    }
  }
}

# --- Budget trigger

resource "aws_sns_topic" "kill_switch_trigger" {
  #checkov:skip=CKV_AWS_26:Budgets can't publish to a topic encrypted with the AWS-managed key, and a customer key costs USD 1 a month
  name = "cost-kill-switch-trigger"
}

resource "aws_sns_topic_policy" "kill_switch_trigger" {
  arn = aws_sns_topic.kill_switch_trigger.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowBudgets"
      Effect    = "Allow"
      Principal = { Service = "budgets.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.kill_switch_trigger.arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:budgets::${local.account_id}:*" }
      }
    }]
  })
}

resource "aws_sns_topic_subscription" "kill_switch_trigger" {
  topic_arn = aws_sns_topic.kill_switch_trigger.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.kill_switch.arn
}

resource "aws_lambda_permission" "kill_switch_trigger" {
  statement_id  = "AllowTriggerTopic"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.kill_switch.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.kill_switch_trigger.arn
}

# --- Alerts

resource "aws_sns_topic" "kill_switch_alerts" {
  #checkov:skip=CKV_AWS_26:Alerts carry no secrets; a customer KMS key costs USD 1 a month
  name = "cost-kill-switch-alerts"
}

resource "aws_sns_topic_policy" "kill_switch_alerts" {
  arn = aws_sns_topic.kill_switch_alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowAlarms"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.kill_switch_alerts.arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = local.kill_switch_alarm_arns }
      }
    }]
  })
}

resource "aws_sns_topic_subscription" "kill_switch_alerts_email" {
  topic_arn = aws_sns_topic.kill_switch_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email # confirmed once by the owner from the email AWS sends
}

resource "aws_cloudwatch_metric_alarm" "kill_switch_errors" {
  alarm_name          = "cost-kill-switch-errors"
  alarm_description   = "The cost kill switch has failed for 5 minutes in a row."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.kill_switch.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.kill_switch_alerts.arn]
  ok_actions          = [aws_sns_topic.kill_switch_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "kill_switch_heartbeat" {
  alarm_name          = "cost-kill-switch-heartbeat"
  alarm_description   = "The cost kill switch has not run for 10 minutes."
  namespace           = "AWS/Lambda"
  metric_name         = "Invocations"
  dimensions          = { FunctionName = aws_lambda_function.kill_switch.function_name }
  statistic           = "Sum"
  period              = 600
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.kill_switch_alerts.arn]
  ok_actions          = [aws_sns_topic.kill_switch_alerts.arn]
}

# --- The kill-switch workflow (status, trip, rearm)

module "kill_switch_operator" {
  source = "./modules/github-oidc-role"

  name              = "baseline-kill-switch-operator"
  description       = "GitHub Actions role for the kill-switch workflow on ${var.github_owner}/${var.baseline_repo} (kill-switch environment only)."
  oidc_provider_arn = aws_iam_openid_connect_provider.github.arn
  github_owner      = var.github_owner
  github_owner_id   = var.github_owner_id
  github_repo       = var.baseline_repo
  github_repo_id    = var.baseline_repo_id
  subject_claims    = ["environment:kill-switch"]
  policy_json = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Sid = "InvokeKillSwitch", Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = local.kill_switch_function_arn }]
  })
}
