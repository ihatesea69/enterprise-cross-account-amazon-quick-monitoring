# Cross-account: monitor another account's Amazon Quick from this account

The dashboard, pipeline and data stay in the **collector** account. The **source** (monitored)
account only gets delivery sources, deliveries and one read-only role.

```
source account                          collector account
--------------                          -----------------
Quick (logs emitted in us-east-1)       us-east-1: delivery destination <prefix>-logs-s3
  delivery sources (chat, feedback,  -->           + destination policy (source account may CreateDelivery)
  agent-hours), no message text         ap-southeast-1: bucket <acct>-<prefix>-logs
                                          AWSLogs/<source acct>/quicksuitelogs/...  -> Step Functions -> Parquet
role <prefix>-source-reader  <-- assume --  metadata + user-sync Lambdas (ExternalId)
  QuickSight List/Describe, SPICE           -> Glue/Athena -> SPICE -> dashboard "[Terraform] <display_name>"
  metrics, Identity Store reads
```

## Order

1. Measure the source account first (Quick identity Region, the Region where logs are
   emitted, existing delivery sources, where IAM Identity Center lives).
2. `collector/`: fill in the locals and Regions, `terraform apply`. Note the
   `for_source_account` output.
3. `source/`: run with a profile for the source account, paste the collector outputs,
   `terraform apply`.
4. Use Quick in the source account, wait ~20 minutes, refresh SPICE, count rows.

## Guardrails in the analytics module

When `source_account_id` is another account, `terraform plan` fails unless
`manage_delivery_sources = false` (otherwise this account's own Quick logs would flow into the
source account's dashboard), `cloudtrail_mode` is not `"new"` (a new trail would record THIS
account's API calls) and `source_role_arn` is set.

## Not verified yet

- That Amazon Quick allows a delivery to a destination in another account. The CloudWatch
  Logs API allows it for "Supported [V2 Permissions]" services; Quick is not named there.
- That the destination must be in the same Region as the delivery source. Test with one
  CHAT_LOGS delivery before applying everything.

## Known limitations

- After the FIRST apply, run a FULL_REFRESH on every dataset. The initial ingestions start in
  the same second the module attaches `QuickSightS3Access-<prefix>` to
  `aws-quicksight-service-role-v0`, so they fail with `s3:ListBucket` PERMISSION_DENIED (IAM
  propagation). Scheduled incremental refreshes then keep failing with "The lookback window
  column is not valid" until one full refresh succeeds, and the dashboard shows "Cannot access
  data for this visual". Measured on two separate deployments (2026-10-28).
- Assumed-role credentials are taken once per Lambda cold start (1 hour). The schedules run
  every 6 hours (user sync) and daily (metadata), so a warm container does not outlive them.
- Vended logs are not retroactive: the dashboard starts on the day the deliveries are created.
- Asset Inventory (CloudTrail-based) stays empty with `cloudtrail_mode = "disabled"`.

## Migrating into the customer account

The cross-account setup can be temporary. The delivery sources in the source account are the
part that stays: each Quick log type allows only one source, and one source may feed several
deliveries. Migration therefore adds a second delivery per log type instead of moving
anything, so no day of data is lost.

1. Apply `migrate-in/` in the customer account (`manage_delivery_sources = false`).
2. In `source/`, add `local = <migrate-in output local_delivery_destination_arn>` to
   `delivery_destinations` and apply. Both instances now receive every new event.
3. Copy history from the collector bucket into the new bucket. Copy the processed prefixes
   only: `enriched/`, `enriched_feedback/`, `enriched_agent_hours/`, `enriched_plugins/`,
   `enriched_resource_selections/` and `qs_metadata/spice_capacity/` (SPICE capacity history,
   partitioned by day). Do not copy `AWSLogs/` (raw logs) or `temp/`.
   `user_attributes/users.jsonl` and the other `qs_metadata/` tables are snapshots that the
   first sync rebuilds.
   The copy needs read on the collector bucket and write on the new bucket from one
   principal; grant it for the copy only. Refresh SPICE afterwards.
4. Compare row counts of both dashboards for the same days.
5. In `source/`, remove `collector` from `delivery_destinations` and set
   `create_reader_role = false`; apply. Then `terraform destroy` the collector root.

Not verified yet: the copied Parquet being read by the new Glue tables (same prefixes and
partition layout, so it is expected to work).
