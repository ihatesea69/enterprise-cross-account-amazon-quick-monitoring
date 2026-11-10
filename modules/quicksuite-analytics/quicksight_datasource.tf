resource "aws_quicksight_data_source" "athena" {
  aws_account_id = data.aws_caller_identity.current.account_id
  data_source_id = "${local.name_prefix}-athena"
  name           = "${local.qs_label}QuickSuite Analytics"
  type           = "ATHENA"

  parameters {
    athena {
      work_group = "primary"
      role_arn   = local.quicksight_role_arn # null = account-wide QuickSight service role
    }
  }

  # IAM policies must exist before QuickSight validates the role on create
  depends_on = [
    aws_iam_role_policy_attachment.quicksight_athena_access,
    aws_iam_role_policy.quicksight_athena_scoped,
    aws_iam_role_policy.quicksight_s3_access,
  ]

  permission {
    actions = [
      "quicksight:DescribeDataSource",
      "quicksight:DescribeDataSourcePermissions",
      "quicksight:PassDataSource",
      "quicksight:UpdateDataSource",
      "quicksight:DeleteDataSource",
      "quicksight:UpdateDataSourcePermissions",
    ]
    principal = "arn:aws:quicksight:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:group/${var.quicksight_namespace}/${var.quicksight_admin_group}"
  }
}
