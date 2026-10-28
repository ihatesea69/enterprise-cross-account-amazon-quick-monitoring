import json
import os
import uuid
import boto3

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
    items = []
    params = {"AwsAccountId": account_id}
    while True:
        response = quicksight.list_data_sets(**params)
        for item in response.get("DataSetSummaries", []):
            items.append({
                "dataset_id": item["DataSetId"],
                "name": item["Name"],
                "import_mode": item.get("ImportMode", ""),
            })
        next_token = response.get("NextToken")
        if not next_token:
            break
        params["NextToken"] = next_token

    if not items:
        return {"temp_bucket": bucket, "temp_key": "", "count": 0}

    temp_key = f"temp/qs_metadata/datasets_list/{uuid.uuid4()}.json"
    body = "\n".join(json.dumps(item) for item in items)
    s3.put_object(Bucket=bucket, Key=temp_key, Body=body.encode())
    return {"temp_bucket": bucket, "temp_key": temp_key, "count": len(items)}
