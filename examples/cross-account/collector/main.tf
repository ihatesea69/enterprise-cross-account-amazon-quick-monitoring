# Collector side: runs in the account that hosts the dashboard (for example a partner or
# central monitoring account).
# One instance per monitored account; name_prefix keeps instances apart.
# Apply this FIRST, then ../source with the outputs below.

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  source_account_id = "222222222222" # monitored (customer) account
  name_prefix       = "cust1"
  # Shared secret-ish token; generate once (e.g. a UUID) and give the same value to ../source
  external_id = "REPLACE-WITH-A-UUID-0000"
}

provider "aws" {
  region  = "ap-southeast-1" # where the dashboard and pipeline live
  profile = "collector-profile"
}

provider "aws" {
  alias   = "logs_region"
  region  = "us-east-1" # Region where the customer's Quick emits vended logs (measure first)
  profile = "collector-profile"
}

module "analytics" {
  source = "../../../modules/quicksuite-analytics"

  name_prefix  = local.name_prefix
  display_name = "Amazon Quick Suite Adoption - Customer 1"

  source_account_id      = local.source_account_id
  source_role_arn        = "arn:aws:iam::${local.source_account_id}:role/${local.name_prefix}-source-reader"
  source_external_id     = local.external_id
  source_region          = "ap-southeast-1" # Region of the customer's QuickSight assets
  source_identity_region = "ap-southeast-1" # customer's QuickSight identity Region

  # IAM Identity Center of the customer. Same reader role when IdC lives in the Quick account;
  # otherwise a reader role in the customer's management account.
  identity_store_id       = "d-0000000000"
  identity_store_role_arn = "arn:aws:iam::${local.source_account_id}:role/${local.name_prefix}-source-reader"
  identity_store_region   = "ap-southeast-1"

  manage_delivery_sources = false      # the customer account creates them (../source)
  cloudtrail_mode         = "disabled" # do not read the customer's full API history

  quicksight_admin_group = "REPLACE-with-your-QuickSight-admin-group"
  dashboard_viewers      = { users = ["REPLACE-with-a-QuickSight-user-name"] }

  # Collector-account specifics, uncomment when they apply
  # permissions_boundary_arn = "arn:aws:iam::111111111111:policy/<required-permissions-boundary>"
  # layer_build_shell        = "C:/Program Files/Git/bin/bash.exe" # Windows: Git Bash
  # Optional: reuse the existing instance's layer instead of publishing a second 61 MB copy
  # lambda_layer_arn = "arn:aws:lambda:ap-southeast-1:111111111111:layer:quicksuite-dependencies:<version>"

  categorization_config = {
    enabled         = false
    model_id        = "global.amazon.nova-2-lite-v1:0"
    bedrock_region  = "us-east-1"
    max_concurrency = 5
  }
}

module "log_destination" {
  source    = "../../../modules/quicksuite-log-destination"
  providers = { aws = aws.logs_region }

  name               = "${local.name_prefix}-logs-s3"
  bucket_arn         = module.analytics.bucket_arn
  source_account_ids = [local.source_account_id]
}

output "for_source_account" {
  description = "Inputs for ../source"
  value = {
    collector_role_arns      = module.analytics.source_reader_trusted_role_arns
    delivery_destination_arn = module.log_destination.delivery_destination_arn
  }
}
