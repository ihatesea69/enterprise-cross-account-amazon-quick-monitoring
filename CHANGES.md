# Changes from upstream

This repository is a modified copy of
[aws-samples/sample-quicksuite-usage-dashboard](https://github.com/aws-samples/sample-quicksuite-usage-dashboard)
at commit `f3efc990a46c69edb9c1181fd4d4bbaa71d3e7b3` (2026-07-29), licensed under Apache-2.0.
As required by section 4(b) of the license, the files changed or added here are listed below.

## Summary

- **Cross-account monitoring.** New variables in `quicksuite-analytics`: `name_prefix`,
  `display_name`, `source_account_id`, `source_role_arn`, `source_external_id`,
  `source_region`, `source_identity_region`, `identity_store_region`,
  `manage_delivery_sources`. With the defaults the module behaves as upstream.
- **Several instances per account.** Resource names use `name_prefix`; QuickSight dataset and
  data source display names get a prefix when `name_prefix` is not the default.
- **Lambdas read the monitored account** through an assumed role with an ExternalId (one
  shared code block, kept identical by a unit test).
- **Bucket policy** accepts vended logs from the monitored account and denies reads of its raw
  logs; `terraform plan` refuses unsafe cross-account combinations.
- **Region fixes** for accounts whose Quick emits logs in a Region other than the dashboard
  Region; bucket policy scope so CloudTrail objects stay readable by QuickSight.
- **Windows support** for the Lambda layer build (`layer_build_shell`), and an optional
  pre-built `lambda_layer_arn`.
- **New modules:** `quicksuite-source-account` (monitored-account side, migration-ready
  `delivery_destinations` map, optional reader role) and `quicksuite-log-destination`.
- **New examples:** `examples/cross-account/{collector,source,migrate-in}`.
- **Docs:** new `README.md`, upstream README moved to `docs/single-account-guide.md`,
  architecture diagram `docs/architecture.drawio`. Upstream `CODE_OF_CONDUCT.md` and
  `CONTRIBUTING.md` removed because they direct reports to the upstream maintainers.

## Files added

- `CHANGES.md`, `README.md` (new content), `docs/architecture.drawio`
- `examples/cross-account/README.md`
- `examples/cross-account/collector/main.tf`
- `examples/cross-account/source/main.tf`
- `examples/cross-account/migrate-in/main.tf`
- `modules/quicksuite-log-destination/main.tf`
- `modules/quicksuite-source-account/main.tf`
- `test/unit/test_source_account.py`

## Files modified

- `NOTICE`
- `modules/quicksuite-analytics/`: `cloudtrail.tf`, `cloudwatch_delivery.tf`, `dynamodb.tf`,
  `eventbridge_qs_metadata.tf`, `eventbridge_user_sync.tf`, `glue_tables.tf`,
  `iam_cloudtrail.tf`, `iam_pipeline.tf`, `iam_qs_metadata.tf`, `iam_user_sync.tf`,
  `lambda_pipeline.tf`, `lambda_qs_metadata.tf`, `lambda_user_sync.tf`, `main.tf`,
  `outputs.tf`, `quicksight_dashboard.tf`, `quicksight_dataset.tf`,
  `quicksight_dataset_assets.tf`, `quicksight_dataset_bi_assets.tf`,
  `quicksight_dataset_health.tf`, `quicksight_dataset_idle_users.tf`,
  `quicksight_dataset_plugins.tf`, `quicksight_dataset_resources.tf`,
  `quicksight_dataset_spice_capacity.tf`, `quicksight_dataset_users.tf`,
  `quicksight_datasource.tf`, `s3.tf`, `sfn_log_analytics.tf`, `sfn_qs_metadata.tf`,
  `sfn_user_sync.tf`, `variables.tf`
- `modules/quicksuite-analytics/lambda/*/index.py` for: `qs_collect_datasources`,
  `qs_collect_spice`, `qs_describe_analysis`, `qs_describe_dashboard`, `qs_describe_dataset`,
  `qs_list_analyses`, `qs_list_dashboards`, `qs_list_datasets`, `user_idc_describe`,
  `user_idc_list`, `user_qs_list`

## Files moved or removed

- `README.md` -> `docs/single-account-guide.md` (unchanged)
- `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md` removed
