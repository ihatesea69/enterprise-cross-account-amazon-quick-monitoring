# Single-account deploy: the dashboard and the monitored Amazon Quick live in the SAME account.
# The simplest setup. To monitor a DIFFERENT account from this one, use ../cross-account instead.
#
# Quick start:
#   1. cp terraform.tfvars.example terraform.tfvars   # then fill in the values
#   2. aws sso login --profile <your-profile>         # or export AWS credentials
#   3. terraform init && terraform apply
#
# Prerequisites: Terraform >= 1.9, QuickSight Enterprise with an admin group, IAM Identity
# Center enabled, and Docker running at apply time (unless you set lambda_layer_arn).

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "aws_region" {
  description = "Region where Amazon Quick emits vended logs and the dashboard is built."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Named AWS CLI/SSO profile. null uses the default credential chain."
  type        = string
  default     = null
}

variable "quicksight_admin_group" {
  description = "QuickSight group that gets full access to the dashboard and datasets."
  type        = string
}

variable "dashboard_viewer_groups" {
  description = "Extra QuickSight groups granted view-only access to the dashboard."
  type        = list(string)
  default     = []
}

variable "budget_alert_emails" {
  description = "Emails alerted if the daily S3 request-cost budget is exceeded."
  type        = list(string)
  default     = []
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

data "aws_ssoadmin_instances" "this" {}

module "quicksuite_analytics" {
  source = "../../modules/quicksuite-analytics"

  quicksight_admin_group = var.quicksight_admin_group
  dashboard_viewers      = { groups = var.dashboard_viewer_groups }
  identity_store_id      = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]

  # Cost controls (see the module README). Reading only ~3 months of partitions and
  # refreshing every 8 hours instead of every 15 minutes cuts S3 LIST cost sharply.
  query_lookback_days       = 92
  spice_refresh_daily_times = ["07:00", "15:00", "23:00"]
  spice_refresh_timezone    = "UTC"

  # A daily S3 API-request budget that emails you if LIST cost spikes again. Optional.
  s3_request_daily_budget_usd = 3
  budget_alert_emails         = var.budget_alert_emails

  # Bedrock message categorization is off by default; enable to populate Usage Insights.
  categorization_config = {
    enabled         = false
    model_id        = "global.amazon.nova-2-lite-v1:0"
    bedrock_region  = var.aws_region
    max_concurrency = 5
  }
}

output "dashboard_id" {
  description = "QuickSight dashboard ID."
  value       = module.quicksuite_analytics.dashboard_id
}

output "bucket_name" {
  description = "S3 bucket holding the collected logs."
  value       = module.quicksuite_analytics.bucket_name
}
