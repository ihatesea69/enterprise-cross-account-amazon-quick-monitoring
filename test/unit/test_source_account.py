"""Cross-account (source account) behaviour of the Lambdas that read the monitored account.

Each Lambda is loaded under a unique module name with boto3.client patched, so module-level
client creation is observed without any AWS call.
"""
import importlib.util
import os
import pathlib
import re
import uuid
from unittest.mock import MagicMock, patch

import pytest

LAMBDA = pathlib.Path(__file__).resolve().parents[2] / "modules" / "quicksuite-analytics" / "lambda"
QS_LAMBDAS = [
    "qs_list_datasets", "qs_list_dashboards", "qs_list_analyses", "qs_describe_dataset",
    "qs_describe_dashboard", "qs_describe_analysis", "qs_collect_datasources",
]
BLOCK_LAMBDAS = QS_LAMBDAS + ["qs_collect_spice", "user_qs_list"]
CREDS = {"AccessKeyId": "AKIA_SRC", "SecretAccessKey": "secret_src", "SessionToken": "token_src"}
SOURCE_ENV = {
    "SOURCE_ROLE_ARN": "arn:aws:iam::222222222222:role/cust-source-reader",
    "SOURCE_EXTERNAL_ID": "ext-123",
    "SOURCE_REGION": "us-west-2",
    "SOURCE_ACCOUNT_ID": "222222222222",
    "SOURCE_IDENTITY_REGION": "eu-west-1",
    "BUCKET": "test-bucket",
}


def load(name, env):
    """Import lambda/<name>/index.py with boto3.client mocked; return (module, boto3.client mock, sts mock)."""
    sts = MagicMock()
    sts.assume_role.return_value = {"Credentials": CREDS}
    sts.get_caller_identity.return_value = {"Account": "111111111111"}
    clients = {}

    def client(service, **kwargs):
        if service == "sts":
            return sts
        return clients.setdefault(service, MagicMock(name=service))

    spec = importlib.util.spec_from_file_location(f"lam_{name}_{uuid.uuid4().hex[:6]}", LAMBDA / name / "index.py")
    mod = importlib.util.module_from_spec(spec)
    with patch.dict(os.environ, env, clear=False), patch("boto3.client", side_effect=client) as mock_client:
        spec.loader.exec_module(mod)
    return mod, mock_client, sts


def clear_source_env():
    keys = [k for k in os.environ if k.startswith(("SOURCE_", "IDENTITY_STORE_"))]
    return patch.dict(os.environ, {k: "" for k in keys})


@pytest.mark.parametrize("name", QS_LAMBDAS)
def test_cross_account_quicksight_client(name):
    mod, mock_client, sts = load(name, SOURCE_ENV)
    sts.assume_role.assert_called_once_with(
        RoleArn=SOURCE_ENV["SOURCE_ROLE_ARN"], RoleSessionName="quicksuite-source-reader", ExternalId="ext-123")
    mock_client.assert_any_call(
        "quicksight", region_name="us-west-2", aws_access_key_id="AKIA_SRC",
        aws_secret_access_key="secret_src", aws_session_token="token_src")
    assert mod.account_id == "222222222222"
    sts.get_caller_identity.assert_not_called()


@pytest.mark.parametrize("name", QS_LAMBDAS)
def test_same_account_is_unchanged(name):
    with clear_source_env():
        mod, mock_client, sts = load(name, {})
    sts.assume_role.assert_not_called()
    mock_client.assert_any_call("quicksight")
    assert mod.account_id == "111111111111"


def test_cross_account_spice_metrics():
    pytest.importorskip("pyarrow")
    _, mock_client, sts = load("qs_collect_spice", SOURCE_ENV)
    sts.assume_role.assert_called_once()
    mock_client.assert_any_call(
        "cloudwatch", region_name="us-west-2", aws_access_key_id="AKIA_SRC",
        aws_secret_access_key="secret_src", aws_session_token="token_src")


def test_cross_account_user_qs_list_uses_identity_region_and_source_account():
    mod, mock_client, sts = load("user_qs_list", SOURCE_ENV)
    mock_client.assert_any_call(
        "quicksight", region_name="eu-west-1", aws_access_key_id="AKIA_SRC",
        aws_secret_access_key="secret_src", aws_session_token="token_src")
    mod.quicksight = MagicMock()
    mod.quicksight.get_paginator.return_value.paginate.return_value = [{"UserList": []}]
    mod.s3 = MagicMock()
    mod.sts = MagicMock()
    with patch.dict(os.environ, SOURCE_ENV):
        mod.handler({}, None)
    mod.quicksight.get_paginator.return_value.paginate.assert_called_once_with(
        AwsAccountId="222222222222", Namespace="default")
    mod.sts.get_caller_identity.assert_not_called()


@pytest.mark.parametrize("name", ["user_idc_list", "user_idc_describe"])
def test_identity_store_external_id_and_region(name):
    env = {"IDENTITY_STORE_ID": "d-test", "BUCKET": "test-bucket",
           "IDENTITY_STORE_ROLE_ARN": "arn:aws:iam::222222222222:role/cust-source-reader",
           "IDENTITY_STORE_EXTERNAL_ID": "ext-123", "IDENTITY_STORE_REGION": "eu-west-1"}
    _, mock_client, sts = load(name, env)
    sts.assume_role.assert_called_once_with(
        RoleArn=env["IDENTITY_STORE_ROLE_ARN"], RoleSessionName="quicksuite-idc-sync", ExternalId="ext-123")
    mock_client.assert_any_call(
        "identitystore", aws_access_key_id="AKIA_SRC", aws_secret_access_key="secret_src",
        aws_session_token="token_src", region_name="eu-west-1")


def test_source_block_is_identical_everywhere():
    pattern = re.compile(r"# --- source account block.*?# --- end source account block ---", re.S)
    blocks = {n: pattern.search((LAMBDA / n / "index.py").read_text(encoding="utf-8")).group(0)
              for n in BLOCK_LAMBDAS}
    assert len(set(blocks.values())) == 1, "the shared source-account block drifted between Lambdas"
