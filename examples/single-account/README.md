# Single-account example

Deploy the Amazon Quick usage dashboard in the **same account** that runs Amazon Quick.
This is the simplest, most convenient setup.

## Steps
1. `cp terraform.tfvars.example terraform.tfvars` and fill in the values.
2. Authenticate: `aws sso login --profile <profile>` (or export AWS credentials).
3. `terraform init && terraform apply`.

`identity_store_id` is discovered automatically from IAM Identity Center, so you only
have to supply the QuickSight admin group, Region, and profile.

## Prerequisites
- Terraform `>= 1.9`, AWS provider `~> 6.0`
- QuickSight Enterprise edition with an admin group
- IAM Identity Center enabled in this account/Region
- Docker running at apply time (builds the Lambda layer) - or set `lambda_layer_arn`

## Cost note
This example reads only the last 92 days of data, refreshes every 8 hours, and sets a
small daily S3-request budget. Those settings keep S3 LIST cost low; see the module
README for why the scan window and refresh interval drive that cost.

To monitor a **different** account from this one, use [`../cross-account`](../cross-account) instead.
