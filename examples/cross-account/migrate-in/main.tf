# Phase 2: move the whole monitoring INTO the monitored (customer) account.
#
# The temporary cross-account setup (../collector + ../source) keeps running while this is
# applied. Order, with no day of missing data:
#   1. Apply this root in the customer account. It creates a normal single-account instance
#      (bucket, pipeline, SPICE, dashboard) but NO delivery sources: those already exist,
#      owned by ../source.
#   2. In ../source add  local = <output local_delivery_destination_arn>  to
#      delivery_destinations and apply. Every new event now reaches both pipelines.
#   3. Copy history from the collector bucket (enriched*/ and user_attributes/ prefixes,
#      not the raw AWSLogs/ prefix) into this bucket, then refresh SPICE. See
#      ../README.md "Migrating into the customer account".
#   4. Compare row counts of both dashboards for the same days.
#   5. In ../source remove "collector" and set create_reader_role = false; apply.
#      Then destroy ../collector in the collector account.

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = "us-east-1" # customer's Quick identity Region and log Region (measure first)
  profile = "customer-profile"
}

module "analytics" {
  source = "../../../modules/quicksuite-analytics"

  # A different prefix from the cross-account instance only matters if both ever share an
  # account; here they live in different accounts, so the default name is fine.
  display_name = "Amazon Quick Suite Adoption"

  identity_store_id = "d-0000000000" # this account's IAM Identity Center

  manage_delivery_sources = false # reuse the sources ../source already owns
  cloudtrail_mode         = "disabled"

  quicksight_admin_group = "REPLACE-with-a-group-in-this-account"
  dashboard_viewers      = { users = [] }

  categorization_config = {
    enabled         = false
    model_id        = "global.amazon.nova-2-lite-v1:0"
    bedrock_region  = "us-east-1"
    max_concurrency = 5
  }
}

module "log_destination" {
  source = "../../../modules/quicksuite-log-destination"

  name       = "quicksuite-logs-s3-local"
  bucket_arn = module.analytics.bucket_arn
  # Same-account deliveries need no destination policy.
}

output "local_delivery_destination_arn" {
  description = "Add to ../source delivery_destinations as \"local\"."
  value       = module.log_destination.delivery_destination_arn
}

output "bucket_name" {
  value = module.analytics.bucket_name
}