import uuid
import os
import boto3
from datetime import datetime, timezone, timedelta
from io import BytesIO
import pyarrow as pa
import pyarrow.parquet as pq

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
cloudwatch = _source_client("cloudwatch")


# CloudWatch publishes the SPICE capacity metrics only when consumed or purchased capacity changes
# by 1 MB or more, so a quiet account has no datapoint for days. To keep one point per daily run,
# the latest datapoint inside this lookback is carried forward and stamped with the run time.
CARRY_FORWARD_LOOKBACK_DAYS = int(os.environ.get("SPICE_CARRY_FORWARD_DAYS", "455"))


def _latest_values(now):
    """Most recent (limit, consumed) datapoint within the lookback, or None."""
    resp = cloudwatch.get_metric_data(
        MetricDataQueries=[
            {"Id": mid, "MetricStat": {"Metric": {"Namespace": "AWS/QuickSight", "MetricName": name},
                                       "Period": 3600, "Stat": "Maximum"}}
            for mid, name in (("limit", "SPICECapacityLimitInMB"), ("consumed", "SPICECapacityConsumedInMB"))
        ],
        StartTime=now - timedelta(days=CARRY_FORWARD_LOOKBACK_DAYS),
        EndTime=now,
        ScanBy="TimestampDescending",
        MaxDatapoints=10,
    )
    latest = {}
    for result in resp.get("MetricDataResults", []):
        if result["Values"]:
            latest[result["Id"]] = result["Values"][0]  # TimestampDescending: first is newest
    if not latest:
        return None
    return latest.get("limit", 0.0), latest.get("consumed", 0.0)


def handler(event, context):
    bucket = event["bucket"]
    now = datetime.now(timezone.utc)
    start = now - timedelta(hours=24)

    response = cloudwatch.get_metric_data(
        MetricDataQueries=[
            {
                "Id": "limit",
                "MetricStat": {
                    "Metric": {"Namespace": "AWS/QuickSight", "MetricName": "SPICECapacityLimitInMB"},
                    "Period": 3600,
                    "Stat": "Maximum",
                },
            },
            {
                "Id": "consumed",
                "MetricStat": {
                    "Metric": {"Namespace": "AWS/QuickSight", "MetricName": "SPICECapacityConsumedInMB"},
                    "Period": 3600,
                    "Stat": "Maximum",
                },
            },
        ],
        StartTime=start,
        EndTime=now,
    )

    # Parse results — align timestamps
    limit_data = {}
    consumed_data = {}
    for result in response.get("MetricDataResults", []):
        data_map = limit_data if result["Id"] == "limit" else consumed_data
        for ts, val in zip(result["Timestamps"], result["Values"]):
            data_map[ts.isoformat()] = val

    # Merge into records
    all_timestamps = sorted(set(list(limit_data.keys()) + list(consumed_data.keys())))

    timestamps = []
    limits = []
    consumeds = []
    for ts_str in all_timestamps:
        ts_dt = datetime.fromisoformat(ts_str)
        timestamps.append(int(ts_dt.timestamp() * 1000))  # epoch millis
        limits.append(limit_data.get(ts_str, 0.0))
        consumeds.append(consumed_data.get(ts_str, 0.0))

    carried_forward = False
    if not timestamps:
        latest = _latest_values(now)
        if latest is None:
            return {"output_key": None, "count": 0, "carried_forward": False}
        timestamps.append(int(now.timestamp() * 1000))
        limits.append(latest[0])
        consumeds.append(latest[1])
        carried_forward = True

    # Write Parquet
    table = pa.table({
        "timestamp": pa.array(timestamps, type=pa.int64()),
        "spice_limit_mb": pa.array(limits, type=pa.float64()),
        "spice_consumed_mb": pa.array(consumeds, type=pa.float64()),
    })
    buf = BytesIO()
    pq.write_table(table, buf)

    dt = now
    output_key = f"qs_metadata/spice_capacity/year={dt.year:04d}/month={dt.month:02d}/day={dt.day:02d}/{uuid.uuid4()}.parquet"
    s3.put_object(Bucket=bucket, Key=output_key, Body=buf.getvalue())

    return {"output_key": output_key, "count": len(timestamps), "carried_forward": carried_forward}
