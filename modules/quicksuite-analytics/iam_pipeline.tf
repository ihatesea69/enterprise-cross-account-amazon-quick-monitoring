# Lambda Trigger Role (starts Step Functions)
resource "aws_iam_role" "lambda_trigger" {
  name                 = "${local.name_prefix}-lambda-trigger-role"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "trigger_basic" {
  role       = aws_iam_role.lambda_trigger.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "trigger_sfn" {
  name = "${local.name_prefix}-trigger-sfn"
  role = aws_iam_role.lambda_trigger.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "states:StartExecution"
      Resource = aws_sfn_state_machine.log_analytics.arn
    }]
  })
}

# Lambda Pipeline Role (shared by parser, categorizer, writer)
resource "aws_iam_role" "lambda_pipeline" {
  name                 = "${local.name_prefix}-lambda-pipeline-role"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "pipeline_basic" {
  role       = aws_iam_role.lambda_pipeline.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "pipeline_permissions" {
  name = "${local.name_prefix}-pipeline-permissions"
  role = aws_iam_role.lambda_pipeline.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.quicksuite_logs.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.quicksuite_logs.arn
      }
      ], var.s3_kms_key_arn != null ? [{
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = var.s3_kms_key_arn
      }] : [], var.categorization_config.enabled ? [
      {
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "dynamodb:GetItem"
        Resource = aws_dynamodb_table.categorizer_config[0].arn
      }
    ] : [])
  })
}

# Step Functions Role
resource "aws_iam_role" "sfn" {
  name                 = "${local.name_prefix}-sfn-role"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "sfn_permissions" {
  name = "${local.name_prefix}-sfn-permissions"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([{
      Effect = "Allow"
      Action = "lambda:InvokeFunction"
      Resource = [
        aws_lambda_function.parser.arn,
        aws_lambda_function.categorizer.arn,
        aws_lambda_function.writer.arn,
      ]
      }], var.categorization_config.enabled ? [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.quicksuite_logs.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.quicksuite_logs.arn
      },
      {
        Effect   = "Allow"
        Action   = ["states:StartExecution", "states:DescribeExecution", "states:StopExecution"]
        Resource = aws_sfn_state_machine.log_analytics.arn
      }
      ] : [],
      var.s3_kms_key_arn != null ? [{
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = var.s3_kms_key_arn
    }] : [])
  })
}

# QuickSight Athena access.
#
# The QuickSight service role is account-wide and shared with every other
# QuickSight project in the account. Earlier versions of this module attached
# the AWS-managed AWSQuicksightAthenaAccess to it, so `terraform destroy` of one
# deployment detached the policy and broke Athena for every other dashboard in
# the account. The module now writes a scoped inline policy instead, and the
# `removed` block below makes Terraform forget the old attachment WITHOUT
# detaching it (other projects may still rely on it).
removed {
  from = aws_iam_role_policy_attachment.quicksight_athena_access

  lifecycle {
    destroy = false
  }
}

data "aws_partition" "current" {}

# Scoped Athena + Glue access: the workgroup the data source uses and this
# module's Glue database only. The S3 statement matches AWSQuicksightAthenaAccess:
# with no workgroup output location, QuickSight writes Athena results to
# aws-athena-query-results-*.
resource "aws_iam_role_policy" "quicksight_athena_scoped" {
  name = "QuickSightAthenaAccess-${local.name_prefix}"
  role = var.quicksight_service_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AthenaOnWorkgroup"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution", "athena:StopQueryExecution",
          "athena:GetQueryExecution", "athena:BatchGetQueryExecution",
          "athena:GetQueryResults", "athena:GetQueryResultsStream",
          "athena:GetWorkGroup",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:athena:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:workgroup/primary"
      },
      {
        Sid    = "AthenaCatalogMetadata"
        Effect = "Allow"
        Action = [
          "athena:GetDataCatalog", "athena:GetDatabase", "athena:GetTableMetadata",
          "athena:ListDatabases", "athena:ListTableMetadata",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:athena:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:datacatalog/AwsDataCatalog"
      },
      {
        Sid      = "AthenaListOnly"
        Effect   = "Allow"
        Action   = ["athena:ListWorkGroups", "athena:ListDataCatalogs", "athena:ListEngineVersions"]
        Resource = "*"
      },
      {
        Sid    = "GlueReadDatabase"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables",
          "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition",
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.quicksuite.name}",
          "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.quicksuite.name}/*",
        ]
      },
      {
        Sid    = "AthenaQueryResultsBucket"
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket",
          "s3:ListBucketMultipartUploads", "s3:ListMultipartUploadParts",
          "s3:AbortMultipartUpload", "s3:CreateBucket", "s3:PutObject",
          "s3:PutBucketPublicAccessBlock",
        ]
        Resource = ["arn:${data.aws_partition.current.partition}:s3:::aws-athena-query-results-*"]
      },
      {
        Sid      = "LakeFormationDataAccess"
        Effect   = "Allow"
        Action   = "lakeformation:GetDataAccess"
        Resource = "*"
      },
    ]
  })
}

# QuickSight S3 access policy
resource "aws_iam_role_policy" "quicksight_s3_access" {
  name = "QuickSightS3Access-${local.name_prefix}"
  role = var.quicksight_service_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:GetBucketLocation", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.quicksuite_logs.arn,
          "${aws_s3_bucket.quicksuite_logs.arn}/*",
        ]
      }
      ], var.s3_kms_key_arn != null ? [{
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = var.s3_kms_key_arn
    }] : [])
  })
}
