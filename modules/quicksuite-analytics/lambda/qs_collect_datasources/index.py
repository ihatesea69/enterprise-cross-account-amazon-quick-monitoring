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


s3 = boto3.client("s3")
quicksight = _source_client("quicksight")
account_id = _source_account_id()


def handler(event, context):
    bucket = event["bucket"]
    now = datetime.now(timezone.utc).isoformat()

    # 1. Collect all datasources
    datasources = {}  # id -> {name, type}
    params = {"AwsAccountId": account_id}
    while True:
        resp = quicksight.list_data_sources(**params)
        for ds in resp.get("DataSources", []):
            ds_id = ds["DataSourceId"]
            datasources[ds_id] = {"name": ds.get("Name", ""), "type": ds.get("Type", "")}
        if "NextToken" not in resp:
            break
        params["NextToken"] = resp["NextToken"]

    # 2. Collect all datasets and map to datasources
    records = []
    ds_params = {"AwsAccountId": account_id}
    while True:
        resp = quicksight.list_data_sets(**ds_params)
        for ds_summary in resp.get("DataSetSummaries", []):
            dataset_id = ds_summary["DataSetId"]
            dataset_name = ds_summary.get("Name", "")
            try:
                ds_detail = quicksight.describe_data_set(AwsAccountId=account_id, DataSetId=dataset_id)["DataSet"]
                for table_id, table in ds_detail.get("PhysicalTableMap", {}).items():
                    ds_arn = None
                    for key in ("RelationalTable", "CustomSql", "S3Source"):
                        if key in table:
                            ds_arn = table[key].get("DataSourceArn")
                            break
                    if ds_arn:
                        ds_id = ds_arn.split("/")[-1]
                        ds_info = datasources.get(ds_id, {"name": "Unknown", "type": "Unknown"})
                        records.append({
                            "datasource_id": ds_id,
                            "datasource_name": ds_info["name"],
                            "datasource_type": ds_info["type"],
                            "dataset_id": dataset_id,
                            "dataset_name": dataset_name,
                            "dataset_last_updated_time": str(ds_detail.get("LastUpdatedTime", "")),
                            "dataset_created_time": str(ds_detail.get("CreatedTime", "")),
                            "synced_at": now,
                        })
            except Exception:
                continue  # Skip datasets we can't describe
        if "NextToken" not in resp:
            break
        ds_params["NextToken"] = resp["NextToken"]

    # 3. Write JSONL
    output_key = "qs_metadata/datasources/data.jsonl"
    if records:
        body = "\n".join(json.dumps(r) for r in records)
        s3.put_object(Bucket=bucket, Key=output_key, Body=body.encode())

    return {"output_key": output_key, "count": len(records)}
