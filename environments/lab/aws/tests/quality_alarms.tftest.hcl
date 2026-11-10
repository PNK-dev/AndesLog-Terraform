mock_provider "aws" {
  alias           = "primary"
  override_during = plan
}
mock_provider "aws" {
  alias           = "secondary"
  override_during = plan
}
mock_provider "random" {
  override_during = plan
}
override_data {
  target          = data.aws_availability_zones.available
  override_during = plan
  values          = { names = ["us-east-1a", "us-east-1b"], zone_ids = ["use1-az1", "use1-az2"] }
}
override_data {
  target          = data.aws_caller_identity.current
  override_during = plan
  values          = { account_id = "123456789012" }
}
override_resource {
  target          = aws_sns_topic.alarm_email[0]
  override_during = plan
  values          = { arn = "arn:aws:sns:us-east-1:123456789012:andeslog-test" }
}
override_resource {
  target          = aws_lb.web
  override_during = plan
  values = {
    arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/andeslog-lab-alb/0123456789abcdef"
    arn_suffix = "app/andeslog-lab-alb/0123456789abcdef"
  }
}
override_resource {
  target          = aws_lb_target_group.web
  override_during = plan
  values = {
    arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/andeslog-lab-web/0123456789abcdef"
    arn_suffix = "targetgroup/andeslog-lab-web/0123456789abcdef"
  }
}

run "quality_alarms_with_email" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables { notification_email = "operator@example.com" }
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.alb_error_rate.threshold == 5 &&
      aws_cloudwatch_metric_alarm.alb_error_rate.evaluation_periods == 3 &&
      aws_cloudwatch_metric_alarm.alb_error_rate.datapoints_to_alarm == 2 &&
      length(aws_cloudwatch_metric_alarm.alb_error_rate.metric_query) == 8
    )
    error_message = "La alarma 5xx debe medir el porcentaje y notificar según la configuración."
  }
  assert {
    condition = (
      one([for q in aws_cloudwatch_metric_alarm.alb_error_rate.metric_query : q.expression if q.id == "error_rate"]) == "IF(t2 + t3 + t4 + t5 + a3 + a4 + a5 > 0, 100 * (t5 + a5) / (t2 + t3 + t4 + t5 + a3 + a4 + a5), 0)" &&
      alltrue([for q in aws_cloudwatch_metric_alarm.alb_error_rate.metric_query : q.id == "error_rate" ? q.return_data : !q.return_data]) &&
      length(aws_cloudwatch_metric_alarm.alb_error_rate.alarm_actions) == 1 &&
      length(aws_cloudwatch_metric_alarm.alb_target_latency.alarm_actions) == 1
    )
    error_message = "La expresión debe incluir respuestas del ALB y targets, y enviar ambas alarmas al SNS configurado."
  }
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.alb_target_latency.extended_statistic == "p95" &&
      aws_cloudwatch_metric_alarm.alb_target_latency.threshold == 2 &&
      aws_cloudwatch_metric_alarm.alb_target_latency.period == 60 &&
      aws_cloudwatch_metric_alarm.alb_target_latency.evaluation_periods == 3 &&
      aws_cloudwatch_metric_alarm.alb_target_latency.datapoints_to_alarm == 2
    )
    error_message = "La alarma de latencia debe evaluar p95 durante dos de tres minutos."
  }
}

run "quality_alarms_without_email" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables { notification_email = "" }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.alb_error_rate.alarm_actions) == 0 && length(aws_cloudwatch_metric_alarm.alb_target_latency.alarm_actions) == 0
    error_message = "Sin correo, las alarmas no deben prometer notificaciones."
  }
}
