import json
import os
import boto3
from datetime import datetime, timezone

# --- source account block: identical in every Lambda that reads the monitored account ---
def _source_client(service, region_env="SOURCE_REGION"):
    """Client for the monitored account: assumes SOURCE_ROLE_ARN when set, else this account.

    Credentials are assumed once per cold start (1 hour session). The schedules that invoke
    these Lambdas run every 6 hours or less often, so a warm container does not outlive them.
    """
    kwargs = {}
    region = os.environ.get(region_env) or os.environ.get("SOURCE_REGION")
    if region:
        kwargs["region_name"] = region
    role_arn = os.environ.get("SOURCE_ROLE_ARN")
    if role_arn:
        assume = {"RoleArn": role_arn, "RoleSessionName": "quicksuite-source-reader"}
        if os.environ.get("SOURCE_EXTERNAL_ID"):
            assume["ExternalId"] = os.environ["SOURCE_EXTERNAL_ID"]
        creds = boto3.client("sts").assume_role(**assume)["Credentials"]
        kwargs.update(
            aws_access_key_id=creds["AccessKeyId"],
            aws_secret_access_key=creds["SecretAccessKey"],
            aws_session_token=creds["SessionToken"],
        )
    return boto3.client(service, **kwargs)


def _source_account_id():
    """Monitored account ID: SOURCE_ACCOUNT_ID when set, else this account."""
    return os.environ.get("SOURCE_ACCOUNT_ID") or boto3.client("sts").get_caller_identity()["Account"]
# --- end source account block ---


quicksight = _source_client("quicksight")
account_id = _source_account_id()


def handler(event, context):
    dashboard_id = event["dashboard_id"]
    dashboard_name = event["dashboard_name"]

    now_iso = datetime.now(timezone.utc).isoformat()

    dashboard = quicksight.describe_dashboard(
        AwsAccountId=account_id, DashboardId=dashboard_id
    )["Dashboard"]

    dataset_arns = dashboard.get("Version", {}).get("DataSetArns", [])

    records = []
    for arn in dataset_arns:
        dataset_id = arn.split("/")[-1]
        try:
            ds = quicksight.describe_data_set(
                AwsAccountId=account_id, DataSetId=dataset_id
            )["DataSet"]
        except Exception:
            continue

        records.append({
            "dashboard_id": dashboard_id,
            "dashboard_name": dashboard_name,
            "dataset_id": dataset_id,
            "dataset_name": ds.get("Name", ""),
            "dataset_last_updated_time": str(ds.get("LastUpdatedTime", "")),
            "dataset_created_time": str(ds.get("CreatedTime", "")),
            "synced_at": now_iso,
        })

    return records
