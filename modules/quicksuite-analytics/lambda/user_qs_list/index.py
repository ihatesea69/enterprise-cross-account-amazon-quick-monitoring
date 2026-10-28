import json
import os

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


quicksight = _source_client("quicksight", "SOURCE_IDENTITY_REGION")
s3 = boto3.client("s3")
sts = boto3.client("sts")

QS_LIST_KEY = "temp/qs_users.json"


def handler(event, context):
    """Paginate quicksight:ListUsers, write username->role mapping to temp/qs_users.json."""
    bucket = os.environ["BUCKET"]
    account_id = os.environ.get("SOURCE_ACCOUNT_ID") or sts.get_caller_identity()["Account"]

    paginator = quicksight.get_paginator("list_users")
    qs_users = {}
    for page in paginator.paginate(AwsAccountId=account_id, Namespace="default"):
        for user in page.get("UserList", []):
            username = user["UserName"]
            qs_users[username] = {
                "quicksight_role": user.get("Role"),
                "quicksight_email": user.get("Email"),
                "quicksight_active": user.get("Active"),
            }

    s3.put_object(
        Bucket=bucket,
        Key=QS_LIST_KEY,
        Body=json.dumps(qs_users).encode("utf-8"),
        ContentType="application/json",
    )

    return {"qs_list_key": QS_LIST_KEY, "qs_count": len(qs_users)}
