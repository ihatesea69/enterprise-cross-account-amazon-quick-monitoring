import json
import os
from datetime import timezone

import boto3


def get_identitystore_client():
    region = os.environ.get("IDENTITY_STORE_REGION")
    kwargs = {"region_name": region} if region else {}
    role_arn = os.environ.get("IDENTITY_STORE_ROLE_ARN")
    if role_arn:
        sts = boto3.client("sts")
        assume = {"RoleArn": role_arn, "RoleSessionName": "quicksuite-idc-sync"}
        if os.environ.get("IDENTITY_STORE_EXTERNAL_ID"):
            assume["ExternalId"] = os.environ["IDENTITY_STORE_EXTERNAL_ID"]
        creds = sts.assume_role(**assume)["Credentials"]
        return boto3.client(
            "identitystore",
            aws_access_key_id=creds["AccessKeyId"],
            aws_secret_access_key=creds["SecretAccessKey"],
            aws_session_token=creds["SessionToken"],
            **kwargs,
        )
    return boto3.client("identitystore", **kwargs)


identitystore = get_identitystore_client()
s3 = boto3.client("s3")


def _get_extension(user, ext_name):
    """Extract a named extension dict from a DescribeUser response."""
    extensions = user.get("Extensions", {})
    return extensions.get(ext_name, {})


def _ci_get(d, *names):
    """Case-insensitive lookup over candidate key names.

    SCIM-provisioned users (e.g. from Microsoft Entra ID) come back with lowercase SCIM keys
    ('department', 'costCenter', manager 'displayName'/'value'), while users edited in the
    Identity Center console use 'Department', 'CostCenter', manager 'Name'/'UserName'.
    """
    if not isinstance(d, dict):
        return None
    lowered = {str(k).lower(): v for k, v in d.items()}
    for n in names:
        v = lowered.get(n.lower())
        if v not in (None, ""):
            return v
    return None


def handler(event, context):
    """Describe a single IDC user with enterprise extension, write to temp/idc_users/{user_id}.json."""
    user_id = event["user_id"]
    username = event["username"]

    identity_store_id = os.environ["IDENTITY_STORE_ID"]
    bucket = os.environ["BUCKET"]

    response = identitystore.describe_user(
        IdentityStoreId=identity_store_id,
        UserId=user_id,
        Extensions=["aws:identitystore:enterprise"],
    )
    user = response.get("User", response)

    # Basic fields
    display_name = user.get("DisplayName")

    emails = user.get("Emails", [])
    email = emails[0]["Value"] if emails else None

    title = user.get("Title")

    addresses = user.get("Addresses", [])
    country = addresses[0].get("Country") if addresses else None

    # IDC account creation timestamp (tz-aware datetime from boto3)
    created_at_dt = user.get("CreatedAt")
    created_at = (
        created_at_dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        if created_at_dt
        else None
    )

    # Enterprise extension fields
    enterprise = _get_extension(user, "aws:identitystore:enterprise")
    department = _ci_get(enterprise, "Department")
    division = _ci_get(enterprise, "Division")
    organization = _ci_get(enterprise, "Organization")
    cost_center = _ci_get(enterprise, "CostCenter")
    employee_number = _ci_get(enterprise, "EmployeeNumber")

    # Manager: stored as "Name <username>" when available
    manager_obj = _ci_get(enterprise, "Manager") or {}
    if manager_obj:
        manager_name = _ci_get(manager_obj, "Name", "DisplayName") or ""
        manager_username = _ci_get(manager_obj, "UserName", "Value") or ""
        if manager_name and manager_username:
            manager = f"{manager_name} <{manager_username}>"
        elif manager_name:
            manager = manager_name
        elif manager_username:
            manager = manager_username
        else:
            manager = None
    else:
        manager = None

    user_data = {
        "user_id": user_id,
        "username": username,
        "display_name": display_name,
        "email": email,
        "title": title,
        "department": department,
        "division": division,
        "organization": organization,
        "cost_center": cost_center,
        "employee_number": employee_number,
        "country": country,
        "manager": manager,
        "created_at": created_at,
    }

    s3_key = f"temp/idc_users/{user_id}.json"
    s3.put_object(
        Bucket=bucket,
        Key=s3_key,
        Body=json.dumps(user_data).encode("utf-8"),
        ContentType="application/json",
    )

    return {"user_id": user_id}
