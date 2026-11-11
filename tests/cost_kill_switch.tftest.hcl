mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_resource "aws_ce_anomaly_monitor" {
    defaults = {
      arn = "arn:aws:ce::123456789012:anomalymonitor/00000000-0000-0000-0000-000000000000"
    }
  }

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
}

# Distinct ARNs, so a swapped reference (the alerts topic where the trigger belongs) fails.
override_resource {
  target = aws_sns_topic.kill_switch_trigger
  values = { arn = "arn:aws:sns:eu-north-1:123456789012:cost-kill-switch-trigger" }
}

override_resource {
  target = aws_sns_topic.kill_switch_alerts
  values = { arn = "arn:aws:sns:eu-north-1:123456789012:cost-kill-switch-alerts" }
}

override_resource {
  target = aws_lambda_function.kill_switch
  values = { arn = "arn:aws:lambda:eu-north-1:123456789012:function:cost-kill-switch" }
}

override_resource {
  target = aws_iam_role.kill_switch_scheduler
  values = { arn = "arn:aws:iam::123456789012:role/baseline-kill-switch-scheduler" }
}

variables {
  github_owner = "goncalofileno"
  alert_email  = "alerts@example.com"
}

run "the_function_is_configured_as_designed" {
  command = apply

  assert {
    condition = (
      aws_lambda_function.kill_switch.function_name == "cost-kill-switch" &&
      aws_lambda_function.kill_switch.runtime == "python3.13" &&
      aws_lambda_function.kill_switch.handler == "handler.lambda_handler" &&
      aws_lambda_function.kill_switch.memory_size == 128 &&
      aws_lambda_function.kill_switch.timeout == 60 &&
      aws_lambda_function.kill_switch.reserved_concurrent_executions == 1
    )
    error_message = "cost-kill-switch: Python 3.13, handler.lambda_handler, 128 MB, 60 s, reserved concurrency 1."
  }

  assert {
    condition = aws_lambda_function.kill_switch.environment[0].variables == tomap({
      STATE_PARAMETER   = "/cost-kill-switch/state"
      ALERTS_TOPIC_ARN  = "arn:aws:sns:eu-north-1:123456789012:cost-kill-switch-alerts"
      TRIGGER_TOPIC_ARN = "arn:aws:sns:eu-north-1:123456789012:cost-kill-switch-trigger"
      THRESHOLD_USD     = "5"

      MAX_DISTRIBUTIONS        = "1"
      MAX_APIS                 = "1"
      MAX_FUNCTIONS            = "1"
      FREE_CLOUDFRONT_BYTES    = "1000000000000"
      FREE_CLOUDFRONT_REQUESTS = "10000000"
    })
    error_message = "The function must get exactly the state parameter, both topics, the USD 5 threshold, the inventory limits and the CloudFront free allowance (plain decimal strings)."
  }

  assert {
    condition     = aws_iam_role.kill_switch.name == "baseline-cost-kill-switch" && aws_lambda_function.kill_switch.role == aws_iam_role.kill_switch.arn
    error_message = "The function must run as baseline-cost-kill-switch."
  }

  assert {
    condition     = aws_cloudwatch_log_group.kill_switch.name == "/aws/lambda/cost-kill-switch" && aws_cloudwatch_log_group.kill_switch.retention_in_days == 30
    error_message = "Log group /aws/lambda/cost-kill-switch with 30-day retention."
  }

  assert {
    condition = jsondecode(aws_iam_role.kill_switch.assume_role_policy).Statement == [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
    error_message = "Only the Lambda service may assume the kill switch role (no aws:SourceAccount: Lambda execution roles don't take it)."
  }
}

run "the_function_policy_matches_exactly" {
  command = apply

  assert {
    condition = [for s in jsondecode(aws_iam_role_policy.kill_switch.policy).Statement : s.Sid] == [
      "ReadMetrics", "ListDistributions", "SwitchDistributions", "ListApis", "SwitchApiEndpoints", "ListFunctions",
      "FunctionConcurrency", "NotItself", "State", "Alerts", "Logs",
    ]
    error_message = "Kill switch policy must declare exactly these statements, in this order."
  }

  assert {
    condition = {
      for s in jsondecode(aws_iam_role_policy.kill_switch.policy).Statement :
      s.Sid => { Effect = s.Effect, Action = flatten([s.Action]), Resource = flatten([s.Resource]) }
      } == {
      ReadMetrics         = { Effect = "Allow", Action = ["cloudwatch:GetMetricStatistics"], Resource = ["*"] }
      ListDistributions   = { Effect = "Allow", Action = ["cloudfront:ListDistributions"], Resource = ["*"] }
      SwitchDistributions = { Effect = "Allow", Action = ["cloudfront:GetDistributionConfig", "cloudfront:UpdateDistribution"], Resource = ["arn:aws:cloudfront::123456789012:distribution/*"] }
      ListApis            = { Effect = "Allow", Action = ["apigateway:GET"], Resource = ["arn:aws:apigateway:eu-north-1::/apis"] }
      SwitchApiEndpoints  = { Effect = "Allow", Action = ["apigateway:PATCH"], Resource = ["arn:aws:apigateway:eu-north-1::/apis/*"] }
      ListFunctions       = { Effect = "Allow", Action = ["lambda:ListFunctions"], Resource = ["*"] }
      FunctionConcurrency = { Effect = "Allow", Action = ["lambda:GetFunctionConcurrency", "lambda:PutFunctionConcurrency", "lambda:DeleteFunctionConcurrency"], Resource = ["arn:aws:lambda:eu-north-1:123456789012:function:*"] }
      NotItself           = { Effect = "Deny", Action = ["lambda:PutFunctionConcurrency", "lambda:DeleteFunctionConcurrency"], Resource = ["arn:aws:lambda:eu-north-1:123456789012:function:cost-kill-switch"] }
      State               = { Effect = "Allow", Action = ["ssm:GetParameter", "ssm:PutParameter"], Resource = ["arn:aws:ssm:eu-north-1:123456789012:parameter/cost-kill-switch/state"] }
      Alerts              = { Effect = "Allow", Action = ["sns:Publish"], Resource = ["arn:aws:sns:eu-north-1:123456789012:cost-kill-switch-alerts"] }
      Logs                = { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = ["arn:aws:logs:eu-north-1:123456789012:log-group:/aws/lambda/cost-kill-switch:*"] }
    }
    error_message = "Kill switch policy statements must match exactly (Effect, Action, Resource)."
  }
}

run "the_schedule_checks_every_minute" {
  command = apply

  assert {
    condition = (
      aws_scheduler_schedule.kill_switch_check.name == "cost-kill-switch-check" &&
      aws_scheduler_schedule.kill_switch_check.schedule_expression == "rate(1 minute)" &&
      aws_scheduler_schedule.kill_switch_check.flexible_time_window[0].mode == "OFF" &&
      aws_scheduler_schedule.kill_switch_check.target[0].arn == "arn:aws:lambda:eu-north-1:123456789012:function:cost-kill-switch" &&
      aws_scheduler_schedule.kill_switch_check.target[0].role_arn == "arn:aws:iam::123456789012:role/baseline-kill-switch-scheduler" &&
      jsondecode(aws_scheduler_schedule.kill_switch_check.target[0].input) == { action = "check" } &&
      aws_scheduler_schedule.kill_switch_check.target[0].retry_policy[0].maximum_retry_attempts == 0 &&
      aws_scheduler_schedule.kill_switch_check.target[0].retry_policy[0].maximum_event_age_in_seconds == 60
    )
    error_message = "cost-kill-switch-check: rate(1 minute), no flexible window, input {\"action\":\"check\"}, no retries."
  }

  assert {
    condition = (
      aws_iam_role.kill_switch_scheduler.name == "baseline-kill-switch-scheduler" &&
      jsondecode(aws_iam_role.kill_switch_scheduler.assume_role_policy).Statement == [{
        Effect    = "Allow"
        Principal = { Service = "scheduler.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = { StringEquals = { "aws:SourceAccount" = "123456789012" } }
      }] &&
      jsondecode(aws_iam_role_policy.kill_switch_scheduler.policy).Statement == [{
        Sid = "InvokeKillSwitch", Effect = "Allow", Action = "lambda:InvokeFunction", Resource = "arn:aws:lambda:eu-north-1:123456789012:function:cost-kill-switch"
      }]
    )
    error_message = "The scheduler role may only invoke the kill switch."
  }
}

run "the_topics_are_wired_as_designed" {
  command = apply

  assert {
    condition = jsondecode(aws_sns_topic_policy.kill_switch_trigger.policy).Statement == [{
      Sid       = "AllowBudgets"
      Effect    = "Allow"
      Principal = { Service = "budgets.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = "arn:aws:sns:eu-north-1:123456789012:cost-kill-switch-trigger"
      Condition = {
        StringEquals = { "aws:SourceAccount" = "123456789012" }
        ArnLike      = { "aws:SourceArn" = "arn:aws:budgets::123456789012:*" }
      }
    }]
    error_message = "Only this account's budgets may publish to the trigger topic."
  }

  assert {
    condition = jsondecode(aws_sns_topic_policy.kill_switch_alerts.policy).Statement == [{
      Sid       = "AllowAlarms"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = "arn:aws:sns:eu-north-1:123456789012:cost-kill-switch-alerts"
      Condition = {
        StringEquals = { "aws:SourceAccount" = "123456789012" }
        ArnLike      = { "aws:SourceArn" = "arn:aws:cloudwatch:eu-north-1:123456789012:alarm:cost-kill-switch-*" }
      }
    }]
    error_message = "Only the kill switch alarms may publish to the alerts topic as a service."
  }

  assert {
    condition = (
      aws_sns_topic_subscription.kill_switch_trigger.protocol == "lambda" &&
      aws_sns_topic_subscription.kill_switch_trigger.topic_arn == "arn:aws:sns:eu-north-1:123456789012:cost-kill-switch-trigger" &&
      aws_sns_topic_subscription.kill_switch_trigger.endpoint == "arn:aws:lambda:eu-north-1:123456789012:function:cost-kill-switch" &&
      aws_lambda_permission.kill_switch_trigger.principal == "sns.amazonaws.com" &&
      aws_lambda_permission.kill_switch_trigger.action == "lambda:InvokeFunction" &&
      aws_lambda_permission.kill_switch_trigger.function_name == "cost-kill-switch" &&
      aws_lambda_permission.kill_switch_trigger.source_arn == "arn:aws:sns:eu-north-1:123456789012:cost-kill-switch-trigger"
    )
    error_message = "The trigger topic invokes the function, and only that topic may."
  }

  assert {
    condition = (
      aws_sns_topic_subscription.kill_switch_alerts_email.protocol == "email" &&
      aws_sns_topic_subscription.kill_switch_alerts_email.endpoint == "alerts@example.com" &&
      aws_sns_topic_subscription.kill_switch_alerts_email.topic_arn == "arn:aws:sns:eu-north-1:123456789012:cost-kill-switch-alerts"
    )
    error_message = "The alerts topic emails var.alert_email."
  }
}

run "the_alarms_watch_the_function" {
  command = apply

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.kill_switch_errors.alarm_name == "cost-kill-switch-errors" &&
      aws_cloudwatch_metric_alarm.kill_switch_errors.namespace == "AWS/Lambda" &&
      aws_cloudwatch_metric_alarm.kill_switch_errors.metric_name == "Errors" &&
      aws_cloudwatch_metric_alarm.kill_switch_errors.dimensions == tomap({ FunctionName = "cost-kill-switch" }) &&
      aws_cloudwatch_metric_alarm.kill_switch_errors.statistic == "Sum" &&
      aws_cloudwatch_metric_alarm.kill_switch_errors.period == 60 &&
      aws_cloudwatch_metric_alarm.kill_switch_errors.evaluation_periods == 5 &&
      aws_cloudwatch_metric_alarm.kill_switch_errors.datapoints_to_alarm == 5 &&
      aws_cloudwatch_metric_alarm.kill_switch_errors.threshold == 1 &&
      aws_cloudwatch_metric_alarm.kill_switch_errors.comparison_operator == "GreaterThanOrEqualToThreshold" &&
      aws_cloudwatch_metric_alarm.kill_switch_errors.treat_missing_data == "notBreaching"
    )
    error_message = "cost-kill-switch-errors: Errors Sum >= 1 in 5 of 5 one-minute periods, missing data not breaching."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.kill_switch_heartbeat.alarm_name == "cost-kill-switch-heartbeat" &&
      aws_cloudwatch_metric_alarm.kill_switch_heartbeat.metric_name == "Invocations" &&
      aws_cloudwatch_metric_alarm.kill_switch_heartbeat.dimensions == tomap({ FunctionName = "cost-kill-switch" }) &&
      aws_cloudwatch_metric_alarm.kill_switch_heartbeat.period == 600 &&
      aws_cloudwatch_metric_alarm.kill_switch_heartbeat.evaluation_periods == 1 &&
      aws_cloudwatch_metric_alarm.kill_switch_heartbeat.threshold == 1 &&
      aws_cloudwatch_metric_alarm.kill_switch_heartbeat.comparison_operator == "LessThanThreshold" &&
      aws_cloudwatch_metric_alarm.kill_switch_heartbeat.treat_missing_data == "breaching"
    )
    error_message = "cost-kill-switch-heartbeat: fewer than 1 invocation in 10 minutes, missing data breaching."
  }

  assert {
    condition = alltrue([
      for a in [aws_cloudwatch_metric_alarm.kill_switch_errors, aws_cloudwatch_metric_alarm.kill_switch_heartbeat] :
      tolist(a.alarm_actions) == tolist(["arn:aws:sns:eu-north-1:123456789012:cost-kill-switch-alerts"]) &&
      tolist(a.ok_actions) == tolist(["arn:aws:sns:eu-north-1:123456789012:cost-kill-switch-alerts"])
    ])
    error_message = "Both alarms email through the alerts topic, on alarm and on OK."
  }
}

run "the_state_starts_armed" {
  command = apply

  assert {
    condition = (
      aws_ssm_parameter.kill_switch_state.name == "/cost-kill-switch/state" &&
      aws_ssm_parameter.kill_switch_state.type == "String" &&
      aws_ssm_parameter.kill_switch_state.value == "{\"acknowledged_usd\":0,\"concurrency\":{},\"disabled_apis\":[],\"disabled_distributions\":[],\"estimate_usd\":null,\"month\":\"1970-01\",\"reason\":null,\"status\":\"armed\",\"tripped_at\":null}"
    )
    error_message = "The state parameter must start as the armed document the Lambda's tests pin (test_state.py TERRAFORM_INITIAL)."
  }
}

run "the_budget_trips_the_switch_at_ten_and_twenty_dollars" {
  command = apply

  assert {
    condition = alltrue([
      for t in [200, 400] : anytrue([
        for n in aws_budgets_budget.monthly_cost.notification :
        n.notification_type == "ACTUAL" && n.threshold == t && n.threshold_type == "PERCENTAGE" &&
        try(tolist(n.subscriber_sns_topic_arns), []) == tolist(["arn:aws:sns:eu-north-1:123456789012:cost-kill-switch-trigger"]) &&
        try(length(n.subscriber_email_addresses), 0) == 0
      ])
    ])
    error_message = "The budget must publish to the trigger topic at 200 % and 400 % of actual spend."
  }
}

run "the_operator_role_only_invokes_the_switch" {
  command = apply

  assert {
    condition     = jsondecode(module.kill_switch_operator.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:goncalofileno@99756598/aws-account-baseline@1394684072:environment:kill-switch"]
    error_message = "baseline-kill-switch-operator must only trust this repo's kill-switch environment."
  }

  assert {
    condition = jsondecode(module.kill_switch_operator.policy).Statement == [{
      Sid = "InvokeKillSwitch", Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = "arn:aws:lambda:eu-north-1:123456789012:function:cost-kill-switch"
    }]
    error_message = "baseline-kill-switch-operator may only invoke the kill switch."
  }
}

run "custom_limits_reach_the_function" {
  command = apply

  variables {
    kill_switch_max_distributions        = 3
    kill_switch_max_apis                 = 2
    kill_switch_max_functions            = 5
    kill_switch_free_cloudfront_bytes    = 0
    kill_switch_free_cloudfront_requests = 20000000
  }

  assert {
    condition = (
      aws_lambda_function.kill_switch.environment[0].variables["MAX_DISTRIBUTIONS"] == "3" &&
      aws_lambda_function.kill_switch.environment[0].variables["MAX_APIS"] == "2" &&
      aws_lambda_function.kill_switch.environment[0].variables["MAX_FUNCTIONS"] == "5" &&
      aws_lambda_function.kill_switch.environment[0].variables["FREE_CLOUDFRONT_BYTES"] == "0" &&
      aws_lambda_function.kill_switch.environment[0].variables["FREE_CLOUDFRONT_REQUESTS"] == "20000000"
    )
    error_message = "The limit and allowance variables must reach the function's environment."
  }
}
