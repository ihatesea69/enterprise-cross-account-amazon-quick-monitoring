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

# Optional dedicated role for the Athena data source (var.create_quicksight_athena_role).
# Leaves the account-wide QuickSight service role untouched.
resource "aws_iam_role" "quicksight_athena" {
  count                = var.create_quicksight_athena_role ? 1 : 0
  name                 = "${local.name_prefix}-quicksight-athena"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "quicksight.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

locals {
  quicksight_role_name = var.create_quicksight_athena_role ? aws_iam_role.quicksight_athena[0].name : var.quicksight_service_role_name
  quicksight_role_arn  = var.create_quicksight_athena_role ? aws_iam_role.quicksight_athena[0].arn : null
}

# QuickSight Athena access (AWS-managed policy), ONLY on the module's own role.
# The account-wide QuickSight service role is shared with other projects: an
# attachment owned by this module was detached on `terraform destroy`
# (2026-11-02) and broke every other dashboard in the account. On the shared
# role the module writes the scoped inline policy below instead.
resource "aws_iam_role_policy_attachment" "quicksight_athena_access" {
  count      = var.create_quicksight_athena_role ? 1 : 0
  role       = local.quicksight_role_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSQuicksightAthenaAccess"
}

data "aws_partition" "current" {}

# Scoped Athena + Glue access on the shared QuickSight service role: the
# workgroup the data source uses and this module's Glue database only. The S3
# statement matches AWSQuicksightAthenaAccess: with no workgroup output
# location, QuickSight writes Athena results to aws-athena-query-results-*.
resource "aws_iam_role_policy" "quicksight_athena_scoped" {
  count = var.create_quicksight_athena_role ? 0 : 1
  name  = "QuickSightAthenaAccess-${local.name_prefix}"
  role  = local.quicksight_role_name
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
        Resource = "arn:${data.aws_partition.current.partition}:athena:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:workgroup/primary"
      },
      {
        Sid    = "AthenaCatalogMetadata"
        Effect = "Allow"
        Action = [
          "athena:GetDataCatalog", "athena:GetDatabase", "athena:GetTableMetadata",
          "athena:ListDatabases", "athena:ListTableMetadata",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:athena:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:datacatalog/AwsDataCatalog"
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
          "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.quicksuite.name}",
          "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.quicksuite.name}/*",
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
  role = local.quicksight_role_name
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
