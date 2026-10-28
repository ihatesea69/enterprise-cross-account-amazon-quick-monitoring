locals {
  bucket_name = "${data.aws_caller_identity.current.account_id}-${local.name_prefix}-logs"
}

resource "aws_s3_bucket" "quicksuite_logs" {
  bucket        = local.bucket_name
  force_destroy = true

  lifecycle {
    # Cross-account guardrails: never mix this account's own Quick data into another account's instance.
    precondition {
      condition     = !local.cross_account || !var.manage_delivery_sources
      error_message = "source_account_id is another account: set manage_delivery_sources = false (the source account creates the deliveries), otherwise this account's own Quick logs would flow into the source account's dashboard."
    }
    precondition {
      condition     = !local.cross_account || var.cloudtrail_mode != "new"
      error_message = "source_account_id is another account: cloudtrail_mode = \"new\" would record THIS account's API activity. Use \"disabled\" or \"existing\" (a trail bucket of the source account)."
    }
    precondition {
      condition     = !local.cross_account || var.source_role_arn != null
      error_message = "source_account_id is another account: source_role_arn is required for the QuickSight metadata and user-list Lambdas."
    }
  }
}

resource "aws_s3_bucket_versioning" "quicksuite_logs" {
  bucket = aws_s3_bucket.quicksuite_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "quicksuite_logs" {
  bucket = aws_s3_bucket.quicksuite_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.s3_kms_key_arn != null ? "aws:kms" : "AES256"
      kms_master_key_id = var.s3_kms_key_arn
    }
    bucket_key_enabled = var.s3_kms_key_arn != null
  }
}

resource "aws_s3_bucket_public_access_block" "quicksuite_logs" {
  bucket                  = aws_s3_bucket.quicksuite_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "quicksuite_logs" {
  bucket = aws_s3_bucket.quicksuite_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid    = "AWSLogDeliveryWrite"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.quicksuite_logs.arn}/*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.log_account_ids
          }
          ArnLike = {
            # Any Region: Quick emits chat logs from us-east-1 even when its identity Region differs
            "aws:SourceArn" = [for a in local.log_account_ids : "arn:aws:logs:*:${a}:*"]
          }
        }
      },
      {
        Sid    = "AWSLogDeliveryAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.quicksuite_logs.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.log_account_ids
          }
          ArnLike = {
            "aws:SourceArn" = [for a in local.log_account_ids : "arn:aws:logs:*:${a}:*"]
          }
        }
      }
    ],
    var.cloudtrail_mode == "new" ? [{
      Sid    = "AWSCloudTrailWrite"
      Effect = "Allow"
      Principal = {
        Service = "cloudtrail.amazonaws.com"
      }
      Action   = "s3:PutObject"
      Resource = "${aws_s3_bucket.quicksuite_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      Condition = {
        StringEquals = {
          "s3:x-amz-acl" = "bucket-owner-full-control"
        }
      }
    }] : [],
    var.cloudtrail_mode == "new" ? [{
      Sid    = "AWSCloudTrailAclCheck"
      Effect = "Allow"
      Principal = {
        Service = "cloudtrail.amazonaws.com"
      }
      Action   = "s3:GetBucketAcl"
      Resource = aws_s3_bucket.quicksuite_logs.arn
    }] : [],
    [{
      Sid       = "DenyPIIGetObject"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:GetObject"
      # Only the raw Quick vended logs are PII. With cloudtrail_mode = "new" the trail also
      # writes under AWSLogs/<acct>/CloudTrail/, which QuickSight must read for asset inventory.
      Resource = concat(
        [for a in local.log_account_ids : "${aws_s3_bucket.quicksuite_logs.arn}/AWSLogs/${a}/quicksuitelogs/*"],
        ["${aws_s3_bucket.quicksuite_logs.arn}/temp/*"],
      )
      Condition = {
        StringNotLike = {
          "aws:PrincipalArn" = [
            aws_iam_role.lambda_pipeline.arn,
            aws_iam_role.lambda_user_sync.arn,
            aws_iam_role.lambda_qs_metadata.arn,
            aws_iam_role.sfn.arn,
            aws_iam_role.sfn_user_sync.arn,
            aws_iam_role.sfn_qs_metadata.arn,
          ]
        }
      }
    },
    {
      Sid       = "DenyPIIListBucket"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:ListBucket"
      Resource  = aws_s3_bucket.quicksuite_logs.arn
      Condition = {
        StringLike = {
          "s3:prefix" = concat([for a in local.log_account_ids : "AWSLogs/${a}/quicksuitelogs/*"], ["temp/*"])
        }
        StringNotLike = {
          "aws:PrincipalArn" = [
            aws_iam_role.lambda_pipeline.arn,
            aws_iam_role.lambda_user_sync.arn,
            aws_iam_role.lambda_qs_metadata.arn,
            aws_iam_role.sfn.arn,
            aws_iam_role.sfn_user_sync.arn,
            aws_iam_role.sfn_qs_metadata.arn,
          ]
        }
      }
    }]
  )
  })
}
