# AGENTS.md - deploy guide for AI assistants

This repo is Terraform that stands up an Amazon Quick (Q Business) **usage dashboard** in
QuickSight: it collects vended logs to S3, enriches them, syncs users/QuickSight metadata,
and builds a 5-tab dashboard. If a user points an assistant at this repo and asks to deploy,
follow this file.

## 1. Pick the mode
- **Single account** - the dashboard and the monitored Amazon Quick live in the same account.
  Simplest; **start here** unless told otherwise. Root: `examples/single-account/`.
- **Cross account** - watch account B from account A, with a no-gap migration path into B
  later. Root: `examples/cross-account/` (apply `collector/` first, then `source/`).
  See `examples/cross-account/README.md`.

## 2. Check prerequisites (verify, do not assume)
- Terraform `>= 1.9`, AWS provider `~> 6.0`.
- AWS credentials for the TARGET account: `aws sso login --profile <p>` or env vars.
  Confirm with `aws sts get-caller-identity`.
- QuickSight **Enterprise** enabled, with an admin group; IAM Identity Center enabled.
- **Docker running** at apply time (the module builds a Lambda layer). No Docker? Build the
  layer once and pass `lambda_layer_arn` - see the module README.
- Know the Region where this account's Amazon Quick emits vended logs; deploy there.

## 3. Deploy (single account)
```bash
cd examples/single-account
cp terraform.tfvars.example terraform.tfvars   # fill quicksight_admin_group, aws_region, aws_profile
terraform init
terraform apply
```
Required inputs: `quicksight_admin_group`, `aws_region`. `identity_store_id` is
auto-discovered from IAM Identity Center by the example.

## 4. Cost - keep these set, they matter
Every SPICE refresh lists S3 partition prefixes. At the stock 15-minute refresh over a
2024-2030 partition projection this runs **millions of S3 LIST requests/day**. The examples
already set safe values - keep them, and warn the user before loosening any:
- `query_lookback_days = 92` - read only ~3 months of partitions, not every projected one.
- `spice_refresh_daily_times = ["07:00","15:00","23:00"]` - every 8h instead of every 15 min.
- `s3_request_daily_budget_usd` + `budget_alert_emails` - a daily budget that emails if
  S3 request cost spikes again.

## 5. Verify after apply
- `terraform output dashboard_id`, open it in QuickSight.
- First load is empty until the initial SPICE ingestion; the module runs a full refresh
  after apply, so give it a few minutes.
- `make validate` and `make test` run Terraform validation and the unit tests.

## 6. Do NOT
- Do not raise refresh frequency or `query_lookback_days` without warning about S3 LIST cost.
- Do not run `terraform destroy` on the shared QuickSight service role's account assumptions
  blindly; read the module README note on the shared `aws-quicksight-service-role-v0`.
- Do not commit a real `terraform.tfvars`, state files, or account-specific values.
