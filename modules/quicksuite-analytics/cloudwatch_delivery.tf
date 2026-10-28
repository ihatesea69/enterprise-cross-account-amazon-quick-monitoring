locals {
  quicksuite_arn = "arn:aws:quicksight:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:account/${data.aws_caller_identity.current.account_id}"
  # Same-account deployments create their own delivery sources. In cross-account mode the
  # source account creates them (modules/quicksuite-source-account) and delivers here.
  manage_deliveries = var.manage_delivery_sources ? 1 : 0
}

resource "aws_cloudwatch_log_delivery_source" "chat" {
  count        = local.manage_deliveries
  name         = "${local.name_prefix}-chat-logs"
  log_type     = "CHAT_LOGS"
  resource_arn = local.quicksuite_arn
}

resource "aws_cloudwatch_log_delivery_source" "feedback" {
  count        = local.manage_deliveries
  name         = "${local.name_prefix}-feedback-logs"
  log_type     = "FEEDBACK_LOGS"
  resource_arn = local.quicksuite_arn
}

resource "aws_cloudwatch_log_delivery_source" "agent_hours" {
  count        = local.manage_deliveries
  name         = "${local.name_prefix}-agent-hours-logs"
  log_type     = "AGENT_HOURS_LOGS"
  resource_arn = local.quicksuite_arn
}

resource "aws_cloudwatch_log_delivery_destination" "s3" {
  count = local.manage_deliveries
  name  = "${local.name_prefix}-logs-s3"
  delivery_destination_configuration {
    destination_resource_arn = aws_s3_bucket.quicksuite_logs.arn
  }
}

resource "aws_cloudwatch_log_delivery" "chat" {
  count                    = local.manage_deliveries
  delivery_source_name     = aws_cloudwatch_log_delivery_source.chat[0].name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.s3[0].arn
}

resource "aws_cloudwatch_log_delivery" "feedback" {
  count                    = local.manage_deliveries
  delivery_source_name     = aws_cloudwatch_log_delivery_source.feedback[0].name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.s3[0].arn
  depends_on               = [aws_cloudwatch_log_delivery.chat]
}

resource "aws_cloudwatch_log_delivery" "agent_hours" {
  count                    = local.manage_deliveries
  delivery_source_name     = aws_cloudwatch_log_delivery_source.agent_hours[0].name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.s3[0].arn
  depends_on               = [aws_cloudwatch_log_delivery.feedback]
}

# Existing deployments created these without count; keep them in place.
moved {
  from = aws_cloudwatch_log_delivery_source.chat
  to   = aws_cloudwatch_log_delivery_source.chat[0]
}

moved {
  from = aws_cloudwatch_log_delivery_source.feedback
  to   = aws_cloudwatch_log_delivery_source.feedback[0]
}

moved {
  from = aws_cloudwatch_log_delivery_source.agent_hours
  to   = aws_cloudwatch_log_delivery_source.agent_hours[0]
}

moved {
  from = aws_cloudwatch_log_delivery_destination.s3
  to   = aws_cloudwatch_log_delivery_destination.s3[0]
}

moved {
  from = aws_cloudwatch_log_delivery.chat
  to   = aws_cloudwatch_log_delivery.chat[0]
}

moved {
  from = aws_cloudwatch_log_delivery.feedback
  to   = aws_cloudwatch_log_delivery.feedback[0]
}

moved {
  from = aws_cloudwatch_log_delivery.agent_hours
  to   = aws_cloudwatch_log_delivery.agent_hours[0]
}
