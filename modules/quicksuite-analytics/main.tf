terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix    = var.name_prefix
  name_prefix_db = replace(var.name_prefix, "-", "_")
  # Display prefix for QuickSight dataset/data source names; empty for the default instance
  # so an existing deployment sees no change.
  qs_label = var.name_prefix == "quicksuite" ? "" : "${upper(var.name_prefix)} - "

  # Cross-account: the monitored (source) account can differ from this (collector) account.
  this_account_id   = data.aws_caller_identity.current.account_id
  source_account_id = coalesce(var.source_account_id, data.aws_caller_identity.current.account_id)
  cross_account     = local.source_account_id != local.this_account_id
  # Accounts whose vended logs may land in the bucket; one element unless cross-account.
  log_account_ids = distinct([local.this_account_id, local.source_account_id])

  # Extra Lambda environment for the source account; empty when every input is null.
  source_env = { for k, v in {
    SOURCE_ACCOUNT_ID  = var.source_account_id
    SOURCE_ROLE_ARN    = var.source_role_arn
    SOURCE_EXTERNAL_ID = var.source_external_id
    SOURCE_REGION      = var.source_region
  } : k => v if v != null }
  identity_store_env = { for k, v in {
    IDENTITY_STORE_REGION      = var.identity_store_region
    IDENTITY_STORE_EXTERNAL_ID = var.identity_store_role_arn != null ? var.source_external_id : null
  } : k => v if v != null }
  # Roles in other accounts the Lambdas may assume
  assume_role_arns = distinct(compact([var.source_role_arn, var.identity_store_role_arn]))

  schedule_rate = {
    MINUTE15 = "rate(15 minutes)"
    MINUTE30 = "rate(30 minutes)"
    HOURLY   = "rate(1 hour)"
    HOURS6   = "rate(6 hours)"
    DAILY    = "rate(1 day)"
  }
}
