# Pieces created in the SOURCE (monitored) account. Nothing here stores data.
#
#   - Quick vended-log delivery sources (unless the account already has them) and deliveries
#     to the collector's destination. Chat message text is never delivered; feedback free
#     text only when include_feedback_text = true.
#   - One read-only role the collector's Lambdas assume (QuickSight List/Describe, SPICE
#     metrics, Identity Store reads), restricted to the collector's two Lambda roles plus
#     an ExternalId.
#
# Run it with a provider in the Region where Quick emits its vended logs (same Region as
# the collector's delivery destination). Apply the collector first: IAM refuses a trust
# policy naming roles that do not exist yet.

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "name_prefix" {
  description = "Same name_prefix as the collector instance."
  type        = string
  default     = "quicksuite"
}

variable "collector_role_arns" {
  description = "Collector output source_reader_trusted_role_arns (the metadata and user-sync Lambda roles). Needed only when create_reader_role = true."
  type        = list(string)
  default     = []
  validation {
    condition     = !var.create_reader_role || length(var.collector_role_arns) > 0
    error_message = "collector_role_arns must be set when create_reader_role = true."
  }
}

variable "external_id" {
  description = "Shared ExternalId; the collector passes it as source_external_id. Needed only when create_reader_role = true."
  type        = string
  default     = null
  validation {
    condition     = !var.create_reader_role || length(coalesce(var.external_id, "")) >= 16
    error_message = "external_id must be at least 16 characters when create_reader_role = true."
  }
}

variable "delivery_destinations" {
  description = <<-EOT
    Label => delivery destination ARN (modules/quicksuite-log-destination output). One
    delivery per log type is created to EACH destination, from the same delivery sources.
    Temporary cross-account phase: { collector = "<collector destination>" }.
    Migration into this account: add { local = "<this account's destination>" } so both
    pipelines receive every new event (no gap), then remove "collector".
  EOT
  type        = map(string)
  validation {
    condition     = length(var.delivery_destinations) > 0 && alltrue([for a in values(var.delivery_destinations) : can(regex("^arn:aws:logs:[a-z0-9-]+:[0-9]{12}:delivery-destination:.+$", a))])
    error_message = "delivery_destinations must map labels to delivery destination ARNs."
  }
}

variable "create_reader_role" {
  description = "Create the read-only role for a collector in another account. Set false once the dashboard runs inside this account."
  type        = bool
  default     = true
}

variable "existing_delivery_sources" {
  description = "Log type => name of a delivery source that already exists for this account's Quick. Each log type allows only one source, so reuse it instead of creating one."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for k in keys(var.existing_delivery_sources) : contains(["CHAT_LOGS", "FEEDBACK_LOGS", "AGENT_HOURS_LOGS"], k)])
    error_message = "Keys must be CHAT_LOGS, FEEDBACK_LOGS or AGENT_HOURS_LOGS."
  }
}

variable "include_feedback_text" {
  description = "Deliver feedback_details (free text the user typed). The dashboard does not use it."
  type        = bool
  default     = false
}

variable "identity_store_access" {
  description = "Grant Identity Store reads on the reader role. Set false when IAM Identity Center lives in another account (create a reader role there instead)."
  type        = bool
  default     = true
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary required by this account for new roles, if any."
  type        = string
  default     = null
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account   = data.aws_caller_identity.current.account_id
  quick_arn = "arn:aws:quicksight:${data.aws_region.current.region}:${local.account}:account/${local.account}"

  # Field lists measured from the defaults of live deliveries (2026-10-28), minus message content.
  chat_fields = [
    "resource_arn", "event_timestamp", "logType", "accountId", "user_arn", "user_type", "status_code",
    "conversation_id", "system_message_id", "message_scope", "user_message_id", "agent_id", "flow_id",
    "user_selected_resources", "action_connectors", "cited_resource", "file_attachment",
  ]
  feedback_fields = concat([
    "resource_arn", "event_timestamp", "logType", "accountId", "user_arn", "user_type", "status_code",
    "conversation_id", "research_id", "system_message_id", "user_message_id", "feedback_type",
    "feedback_reason", "rating",
  ], var.include_feedback_text ? ["feedback_details"] : [])
  agent_hours_fields = [
    "resource_arn", "event_timestamp", "logType", "accountId", "user_arn", "subscription_type",
    "reporting_service", "usage_group", "usage_hours", "service_resource_arn",
  ]

  short          = { CHAT_LOGS = "chat", FEEDBACK_LOGS = "feedback", AGENT_HOURS_LOGS = "agent-hours" }
  create_sources = { for t, s in local.short : t => s if !contains(keys(var.existing_delivery_sources), t) }
  source_names   = { for t, s in local.short : t => lookup(var.existing_delivery_sources, t, "${var.name_prefix}-${s}-logs") }
}

resource "aws_cloudwatch_log_delivery_source" "quick" {
  for_each     = local.create_sources
  name         = "${var.name_prefix}-${each.value}-logs"
  log_type     = each.key
  resource_arn = local.quick_arn
}

# Serialized like the analytics module: parallel CreateDelivery calls to one destination conflict.
# Keyed by destination label, so adding a destination during migration never touches the
# deliveries that already run.
resource "aws_cloudwatch_log_delivery" "chat" {
  for_each                 = var.delivery_destinations
  delivery_source_name     = local.source_names["CHAT_LOGS"]
  delivery_destination_arn = each.value
  record_fields            = local.chat_fields
  depends_on               = [aws_cloudwatch_log_delivery_source.quick]
}

resource "aws_cloudwatch_log_delivery" "feedback" {
  for_each                 = var.delivery_destinations
  delivery_source_name     = local.source_names["FEEDBACK_LOGS"]
  delivery_destination_arn = each.value
  record_fields            = local.feedback_fields
  depends_on               = [aws_cloudwatch_log_delivery.chat]
}

resource "aws_cloudwatch_log_delivery" "agent_hours" {
  for_each                 = var.delivery_destinations
  delivery_source_name     = local.source_names["AGENT_HOURS_LOGS"]
  delivery_destination_arn = each.value
  record_fields            = local.agent_hours_fields
  depends_on               = [aws_cloudwatch_log_delivery.feedback]
}

resource "aws_iam_role" "reader" {
  count                = var.create_reader_role ? 1 : 0
  name                 = "${var.name_prefix}-source-reader"
  description          = "Read-only access for the Quick usage dashboard collector in account ${split(":", var.collector_role_arns[0])[4]}"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.collector_role_arns }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "sts:ExternalId" = var.external_id } }
    }]
  })
}

resource "aws_iam_role_policy" "reader" {
  count = var.create_reader_role ? 1 : 0
  name  = "${var.name_prefix}-source-reader"
  role  = aws_iam_role.reader[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid    = "QuickSightRead"
        Effect = "Allow"
        Action = [
          "quicksight:ListDataSets", "quicksight:DescribeDataSet", "quicksight:DescribeDataSetPermissions",
          "quicksight:ListIngestions", "quicksight:ListDashboards", "quicksight:DescribeDashboard",
          "quicksight:ListAnalyses", "quicksight:DescribeAnalysis", "quicksight:ListDataSources",
          "quicksight:DescribeDataSource", "quicksight:ListUsers",
        ]
        Resource = "*"
      },
      {
        Sid      = "SpiceMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricData"]
        Resource = "*"
      },
      ], var.identity_store_access ? [{
        Sid      = "IdentityStoreRead"
        Effect   = "Allow"
        Action   = ["identitystore:ListUsers", "identitystore:DescribeUser"]
        Resource = "*"
    }] : [])
  })
}

output "reader_role_arn" {
  description = "Pass to the collector as source_role_arn (and identity_store_role_arn when IdC is in this account). Null when create_reader_role = false."
  value       = try(aws_iam_role.reader[0].arn, null)
}

output "delivery_source_names" {
  value = local.source_names
}
