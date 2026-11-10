mock_provider "aws" {}

variables {
  name           = "andeslog-test"
  region         = "us-east-1"
  account_id     = "123456789012"
  alb_arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/test/0123456789abcdef"
  tags           = {}
  rate_limit     = 300
  logs_verified  = false
  rules_reviewed = false
}

run "logging_only" {
  command = plan
  variables { phase = "logging" }
  assert {
    condition     = length(aws_wafv2_web_acl.waf.rule) == 0 && length(aws_wafv2_web_acl.waf.data_protection_config) == 1
    error_message = "La etapa inicial solo registra y protege los campos sensibles."
  }
}

run "count_requires_log_review" {
  command = plan
  variables { phase = "count" }
  expect_failures = [aws_wafv2_web_acl.waf]
}

run "count_rules" {
  command = plan
  variables {
    phase         = "count"
    logs_verified = true
  }
  assert {
    condition     = length(aws_wafv2_web_acl.waf.rule) == 3 && alltrue([for rule in aws_wafv2_web_acl.waf.rule : rule.name == "rate-per-ip" ? length(rule.action[0].count) == 1 : length(rule.override_action[0].count) == 1])
    error_message = "Las tres reglas deben comenzar en modo count."
  }
}

run "enforce_requires_review" {
  command = plan
  variables {
    phase         = "enforce"
    logs_verified = true
  }
  expect_failures = [aws_wafv2_web_acl.waf]
}

run "enforce_rules" {
  command = plan
  variables {
    phase          = "enforce"
    logs_verified  = true
    rules_reviewed = true
  }
  assert {
    condition     = length(aws_wafv2_web_acl.waf.rule) == 3 && alltrue([for rule in aws_wafv2_web_acl.waf.rule : rule.name == "rate-per-ip" ? length(rule.action[0].block) == 1 : length(rule.override_action[0].none) == 1])
    error_message = "La fase enforce debe aplicar las acciones de protección."
  }
}
