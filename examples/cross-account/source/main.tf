# Source side: runs in the MONITORED (customer) account, after ../collector.
# Creates no storage: only delivery sources, deliveries and one read-only role.

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
  region  = "us-east-1"        # Region where this account's Quick emits vended logs
  profile = "customer-profile" # a named profile for the customer account
}

module "source_account" {
  source = "../../../modules/quicksuite-source-account"

  name_prefix = "cust1"
  external_id = "REPLACE-WITH-A-UUID-0000" # same value as the collector

  # From: terraform output for_source_account  (in ../collector)
  collector_role_arns = [
    "arn:aws:iam::111111111111:role/cust1-lambda-qs-metadata-role",
    "arn:aws:iam::111111111111:role/cust1-lambda-user-sync-role",
  ]
  # From: terraform output for_source_account  (in ../collector). Label => destination ARN.
  # Migration into this account later: add a second label for this account's own
  # destination, apply, check both dashboards, then remove "collector" (see ../migrate-in).
  delivery_destinations = {
    collector = "arn:aws:logs:us-east-1:111111111111:delivery-destination:cust1-logs-s3"
  }

  # If the account already has a Quick delivery source for a log type, reuse it:
  # existing_delivery_sources = { CHAT_LOGS = "their-chat-source" }
}

output "reader_role_arn" {
  value = module.source_account.reader_role_arn
}
