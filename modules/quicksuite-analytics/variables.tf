variable "quicksight_admin_group" {
  description = "QuickSight group for dashboard/dataset permissions"
  type        = string
}

variable "dashboard_viewers" {
  description = "Groups and users to grant view-only dashboard access. Use QuickSight group names and usernames (not full ARNs)."
  type = object({
    groups = optional(list(string), [])
    users  = optional(list(string), [])
  })
  default = {
    groups = []
    users  = []
  }
}

variable "quicksight_namespace" {
  description = "QuickSight namespace"
  type        = string
  default     = "default"
}

variable "s3_kms_key_arn" {
  description = "ARN of a customer-managed KMS key for S3 bucket encryption. If null, AES256 (SSE-S3) is used."
  type        = string
  default     = null
}

variable "spice_enabled" {
  description = "Enable SPICE caching for QuickSight dataset"
  type        = bool
  default     = true
}

variable "spice_refresh_interval" {
  description = "SPICE incremental refresh interval (MINUTE15, MINUTE30, HOURLY, DAILY)"
  type        = string
  default     = "MINUTE15"
}

variable "quicksight_service_role_name" {
  description = "Name of the existing QuickSight service IAM role"
  type        = string
  default     = "aws-quicksight-service-role-v0"
}

variable "identity_store_id" {
  description = "IAM Identity Center Identity Store ID"
  type        = string
}

variable "identity_store_role_arn" {
  description = "ARN of an IAM role in the management account to assume for Identity Store API calls. Required for cross-account setups (e.g., Control Tower). When null, calls Identity Store directly (same-account)."
  type        = string
  default     = null
}

variable "name_prefix" {
  description = "Prefix for every resource name, so several instances (one per monitored account) can live in one collector account. Keep the default for an existing deployment: changing it renames, and therefore replaces, every resource."
  type        = string
  default     = "quicksuite"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,19}$", var.name_prefix))
    error_message = "name_prefix must be 2-20 characters: lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "display_name" {
  description = "Analysis name shown in Quick. The dashboard is named \"[Terraform] <display_name>\"."
  type        = string
  default     = "Amazon Quick Suite Adoption"
}

variable "source_account_id" {
  description = "Account whose Amazon Quick is monitored. Null means this (the deployment) account. Set it to collect another account's logs and metadata into this one (cross-account)."
  type        = string
  default     = null
  validation {
    condition     = var.source_account_id == null || can(regex("^[0-9]{12}$", var.source_account_id))
    error_message = "source_account_id must be a 12-digit account ID."
  }
}

variable "source_role_arn" {
  description = "Read-only role in the source account that the QuickSight metadata and user-list Lambdas assume (see modules/quicksuite-source-account). Required when source_account_id is another account."
  type        = string
  default     = null
}

variable "source_external_id" {
  description = "ExternalId passed when assuming source_role_arn and identity_store_role_arn. Must match the source account role trust policy."
  type        = string
  default     = null
}

variable "source_region" {
  description = "Region of the source account's QuickSight assets and SPICE metrics. Null means this Region."
  type        = string
  default     = null
}

variable "source_identity_region" {
  description = "QuickSight identity Region of the source account, used for ListUsers. Null means source_region."
  type        = string
  default     = null
}

variable "identity_store_region" {
  description = "Region of the IAM Identity Center instance. Null means this Region."
  type        = string
  default     = null
}

variable "manage_delivery_sources" {
  description = "Create the Quick vended-log delivery sources and deliveries in this account. Set false in cross-account mode: the source account creates them (modules/quicksuite-source-account)."
  type        = bool
  default     = true
}

variable "lambda_layer_arn" {
  description = "ARN of a pre-built Lambda layer containing boto3 and pyarrow. When provided, skips Docker build and uses this layer for all functions."
  type        = string
  default     = null
}

variable "cloudtrail_mode" {
  description = "CloudTrail integration mode for asset tracking: 'new' (create trail), 'existing' (use existing bucket), or 'disabled'"
  type        = string
  default     = "new"
  validation {
    condition     = contains(["new", "existing", "disabled"], var.cloudtrail_mode)
    error_message = "cloudtrail_mode must be 'new', 'existing', or 'disabled'."
  }
}

variable "cloudtrail_config" {
  description = "Configuration for existing CloudTrail integration (used when cloudtrail_mode = 'existing')"
  type = object({
    s3_bucket = string
    org_id    = optional(string)
    s3_prefix = optional(string)
  })
  default = null
  validation {
    condition     = var.cloudtrail_mode != "existing" || (var.cloudtrail_config != null && var.cloudtrail_config.s3_bucket != "")
    error_message = "cloudtrail_config with s3_bucket is required when cloudtrail_mode = 'existing'."
  }
}

variable "user_tier_config" {
  description = "User segmentation tier configuration"
  type = object({
    power_min_messages   = number
    regular_min_messages = number
    casual_min_messages  = number
    power_percentile     = number
    regular_percentile   = number
    dormant_days         = number
    churned_days         = number
  })
  default = {
    power_min_messages   = 300
    regular_min_messages = 150
    casual_min_messages  = 1
    power_percentile     = 10
    regular_percentile   = 30
    dormant_days         = 30
    churned_days         = 60
  }
}

variable "categorization_config" {
  description = "Bedrock message categorization configuration. For large orgs (10K+ messages/hour), increase max_concurrency to 20-50."
  type = object({
    enabled         = bool
    model_id        = string
    bedrock_region  = string
    max_concurrency = number
  })
  default = {
    enabled         = false
    model_id        = "global.amazon.nova-2-lite-v1:0"
    bedrock_region  = "us-east-1"
    max_concurrency = 5
  }
}

variable "categorization_taxonomy_file" {
  description = "Path to custom taxonomy JSON file (DynamoDB JSON format). If null, uses built-in default at config/default_taxonomy.json."
  type        = string
  default     = null
}

variable "qs_metadata_sync_interval" {
  description = "QuickSight metadata sync frequency (MINUTE15, MINUTE30, HOURLY, HOURS6, DAILY)"
  type        = string
  default     = "DAILY"
  validation {
    condition     = contains(["MINUTE15", "MINUTE30", "HOURLY", "HOURS6", "DAILY"], var.qs_metadata_sync_interval)
    error_message = "qs_metadata_sync_interval must be one of: MINUTE15, MINUTE30, HOURLY, HOURS6, DAILY."
  }
}

variable "user_sync_interval" {
  description = "User sync frequency (MINUTE15, MINUTE30, HOURLY, HOURS6, DAILY)"
  type        = string
  default     = "HOURS6"
  validation {
    condition     = contains(["MINUTE15", "MINUTE30", "HOURLY", "HOURS6", "DAILY"], var.user_sync_interval)
    error_message = "user_sync_interval must be one of: MINUTE15, MINUTE30, HOURLY, HOURS6, DAILY."
  }
}

variable "qs_metadata_lambda_memory" {
  description = "Memory (MB) for QuickSight metadata collector Lambdas. Increase for accounts with 10K+ datasets."
  type        = number
  default     = 256
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary ARN attached to every IAM role this module creates. Null for no boundary."
  type        = string
  default     = null
}

variable "layer_build_shell" {
  description = "Bash interpreter for the Lambda layer local-exec. On Windows use Git Bash, e.g. C:/Program Files/Git/bin/bash.exe"
  type        = string
  default     = "/bin/bash"
}
