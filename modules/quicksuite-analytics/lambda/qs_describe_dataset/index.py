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
    dataset_id = event["dataset_id"]
    name = event["name"]
    import_mode = event["import_mode"]

    now_iso = datetime.now(timezone.utc).isoformat()

    ds = quicksight.describe_data_set(
        AwsAccountId=account_id, DataSetId=dataset_id
    )["DataSet"]

    permissions = quicksight.describe_data_set_permissions(
        AwsAccountId=account_id, DataSetId=dataset_id
    )["Permissions"]

    ingestion = {}
    if import_mode == "SPICE":
        ingestions = quicksight.list_ingestions(
            AwsAccountId=account_id, DataSetId=dataset_id, MaxResults=1
        ).get("Ingestions", [])
        if ingestions:
            ingestion = ingestions[0]

    return {
        "dataset_id": dataset_id,
        "name": name,
        "import_mode": import_mode,
        "last_updated_time": str(ds.get("LastUpdatedTime", "")),
        "consumed_spice_bytes": ds.get("ConsumedSpiceCapacityInBytes", 0),
        "rows_ingested": ingestion.get("RowInfo", {}).get("RowsIngested", 0),
        "rows_dropped": ingestion.get("RowInfo", {}).get("RowsDropped", 0),
        "ingestion_status": ingestion.get("IngestionStatus", ""),
        "refresh_triggered_time": str(ingestion.get("CreatedTime", "")),
        "refresh_time_seconds": ingestion.get("IngestionTimeInSeconds", 0),
        "request_source": ingestion.get("RequestSource", ""),
        "request_type": ingestion.get("RequestType", ""),
        "error_type": ingestion.get("ErrorInfo", {}).get("Type", ""),
        "error_message": ingestion.get("ErrorInfo", {}).get("Message", ""),
        "permission_count": len(permissions),
        "is_orphaned": "Yes" if len(permissions) == 0 else "No",
        "synced_at": now_iso,
    }
