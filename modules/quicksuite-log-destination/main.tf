# Cross-account delivery destination in the COLLECTOR account.
#
# Vended-log destinations are regional: create this in the Region where the source
# account's Amazon Quick emits its logs (measured: us-east-1 even when the Quick identity
# Region is ap-southeast-1). It points at the analytics bucket, which may be in another
# Region, and lets the source accounts create deliveries to it.

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "name" {
  description = "Delivery destination name, e.g. \"<name_prefix>-logs-s3\"."
  type        = string
}

variable "bucket_arn" {
  description = "ARN of the quicksuite-analytics bucket (module output bucket_arn)."
  type        = string
}

variable "source_account_ids" {
  description = "Other accounts allowed to create deliveries to this destination. Leave empty when the delivery sources are in this same account (the migrated, single-account phase)."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for a in var.source_account_ids : can(regex("^[0-9]{12}$", a))])
    error_message = "source_account_ids must be 12-digit account IDs."
  }
}

resource "aws_cloudwatch_log_delivery_destination" "s3" {
  name = var.name
  delivery_destination_configuration {
    destination_resource_arn = var.bucket_arn
  }
}

resource "aws_cloudwatch_log_delivery_destination_policy" "cross_account" {
  count                     = length(var.source_account_ids) > 0 ? 1 : 0
  delivery_destination_name = aws_cloudwatch_log_delivery_destination.s3.name
  delivery_destination_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowSourceAccountsCreateDelivery"
      Effect    = "Allow"
      Principal = { AWS = [for a in var.source_account_ids : "arn:aws:iam::${a}:root"] }
      Action    = "logs:CreateDelivery"
      Resource  = aws_cloudwatch_log_delivery_destination.s3.arn
    }]
  })
}

output "delivery_destination_arn" {
  description = "Pass to modules/quicksuite-source-account as delivery_destination_arn."
  value       = aws_cloudwatch_log_delivery_destination.s3.arn
}
