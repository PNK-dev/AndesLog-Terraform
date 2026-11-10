resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.name}"
  retention_in_days = 14
  tags              = var.tags
}

# CloudWatch vended logs identify their delivery source as an AWS Logs ARN,
# not as a WAF ARN. Restrict both the source account and source region.
resource "aws_cloudwatch_log_resource_policy" "waf" {
  policy_name = "${var.name}-waf-delivery"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AndesLogWafDelivery"
      Effect    = "Allow"
      Principal = { Service = "delivery.logs.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "${aws_cloudwatch_log_group.waf.arn}:*"
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:logs:${var.region}:${var.account_id}:*" }
      }
    }]
  })
}

resource "aws_wafv2_web_acl" "waf" {
  name  = "${var.name}-waf"
  scope = "REGIONAL"
  default_action {
    allow {}
  }

  # WAF logging redaction alone does not protect sampled requests. Apply
  # protection at the ACL level so it covers both samples and logs.
  data_protection_config {
    data_protection {
      action = "SUBSTITUTION"
      field {
        field_type = "SINGLE_HEADER"
        field_keys = ["authorization", "cookie"]
      }
    }
    data_protection {
      action = "SUBSTITUTION"
      field { field_type = "QUERY_STRING" }
    }
    data_protection {
      action = "SUBSTITUTION"
      field { field_type = "BODY" }
    }
  }

  dynamic "rule" {
    for_each = var.phase == "logging" ? {} : {
      core   = { name = "AWSManagedRulesCommonRuleSet", priority = 10 }
      inputs = { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 20 }
    }
    content {
      name     = rule.key
      priority = rule.value.priority
      override_action {
        dynamic "count" {
          for_each = var.phase == "count" ? [1] : []
          content {}
        }
        dynamic "none" {
          for_each = var.phase == "enforce" ? [1] : []
          content {}
        }
      }
      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-${rule.key}"
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = var.phase == "logging" ? [] : [1]
    content {
      name     = "rate-per-ip"
      priority = 30
      action {
        dynamic "count" {
          for_each = var.phase == "count" ? [1] : []
          content {}
        }
        dynamic "block" {
          for_each = var.phase == "enforce" ? [1] : []
          content {}
        }
      }
      statement {
        rate_based_statement {
          aggregate_key_type    = "IP"
          limit                 = var.rate_limit
          evaluation_window_sec = 300
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-rate"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-waf"
    sampled_requests_enabled   = true
  }
  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.phase == "logging" || var.logs_verified
      error_message = "Antes de añadir reglas WAF, confirma que los logs protegidos llegan al destino."
    }
    precondition {
      condition     = var.phase != "enforce" || var.rules_reviewed
      error_message = "Antes de bloquear tráfico, revisa las coincidencias de la fase count."
    }
  }
}

resource "aws_wafv2_web_acl_logging_configuration" "waf" {
  resource_arn            = aws_wafv2_web_acl.waf.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  depends_on              = [aws_cloudwatch_log_resource_policy.waf]
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.waf.arn
  depends_on   = [aws_wafv2_web_acl_logging_configuration.waf]
}

output "web_acl_arn" { value = aws_wafv2_web_acl.waf.arn }
output "log_group_name" { value = aws_cloudwatch_log_group.waf.name }
