resource "aws_quicksight_data_set" "users" {
  aws_account_id = data.aws_caller_identity.current.account_id
  data_set_id    = "${local.name_prefix}-users"
  name           = "${local.qs_label}QuickSuite Users"
  import_mode    = var.spice_enabled ? "SPICE" : "DIRECT_QUERY"

  physical_table_map {
    physical_table_map_id = "users-sql"
    custom_sql {
      data_source_arn = aws_quicksight_data_source.athena.arn
      name            = "all_users"
      sql_query       = <<-EOT
        SELECT u.user_id,
               u.username,
               u.display_name,
               u.email,
               u.title,
               u.department,
               u.country,
               u.employee_number,
               u.quicksight_role,
               u.license_type,
               u.user_tier,
               CAST(from_iso8601_timestamp(u.created_at) AS timestamp) AS account_created_at,
               from_unixtime(u.first_seen_date / 1000) AS first_active_at,
               CAST(u.monthly_agent_hours_allotment AS VARCHAR) AS monthly_agent_hours_allotment,
               coalesce(
                 date_diff('day', from_unixtime(c.last_chat_ms / 1000), current_timestamp),
                 99999
               ) AS days_since_last_used_chat,
               coalesce(
                 date_diff('day', from_unixtime(a.last_agent_sec), current_timestamp),
                 99999
               ) AS days_since_last_used_agent,
               CASE
                 WHEN c.last_chat_ms IS NULL AND a.last_agent_sec IS NULL THEN 99999
                 ELSE date_diff(
                   'day',
                   greatest(
                     coalesce(from_unixtime(c.last_chat_ms / 1000), timestamp '1970-01-01 00:00:00'),
                     coalesce(from_unixtime(a.last_agent_sec),      timestamp '1970-01-01 00:00:00')
                   ),
                   current_timestamp
                 )
               END AS days_since_last_used
        FROM ${aws_glue_catalog_database.quicksuite.name}.user_attributes u
        LEFT JOIN (
          SELECT regexp_extract(user_arn, '[^/]+$') AS username,
                 MAX(event_timestamp) AS last_chat_ms
          FROM ${aws_glue_catalog_database.quicksuite.name}.message_enriched
          GROUP BY 1
        ) c ON c.username = u.username
        LEFT JOIN (
          SELECT regexp_extract(user_arn, '[^/]+$') AS username,
                 MAX(event_timestamp) AS last_agent_sec
          FROM ${aws_glue_catalog_database.quicksuite.name}.agent_hours_enriched
          GROUP BY 1
        ) a ON a.username = u.username
      EOT
      columns {
        name = "user_id"
        type = "STRING"
      }
      columns {
        name = "username"
        type = "STRING"
      }
      columns {
        name = "display_name"
        type = "STRING"
      }
      columns {
        name = "email"
        type = "STRING"
      }
      columns {
        name = "title"
        type = "STRING"
      }
      columns {
        name = "department"
        type = "STRING"
      }
      columns {
        name = "country"
        type = "STRING"
      }
      columns {
        name = "employee_number"
        type = "STRING"
      }
      columns {
        name = "quicksight_role"
        type = "STRING"
      }
      columns {
        name = "license_type"
        type = "STRING"
      }
      columns {
        name = "user_tier"
        type = "STRING"
      }
      columns {
        name = "account_created_at"
        type = "DATETIME"
      }
      columns {
        name = "first_active_at"
        type = "DATETIME"
      }
      columns {
        name = "monthly_agent_hours_allotment"
        type = "STRING"
      }
      columns {
        name = "days_since_last_used_chat"
        type = "INTEGER"
      }
      columns {
        name = "days_since_last_used_agent"
        type = "INTEGER"
      }
      columns {
        name = "days_since_last_used"
        type = "INTEGER"
      }
    }
  }

  logical_table_map {
    logical_table_map_id = "users-logical"
    alias                = "All Users"
    source {
      physical_table_id = "users-sql"
    }
    data_transforms {
      rename_column_operation {
        column_name     = "user_id"
        new_column_name = "User ID"
      }
    }
    data_transforms {
      rename_column_operation {
        column_name     = "display_name"
        new_column_name = "Name"
      }
    }
    data_transforms {
      rename_column_operation {
        column_name     = "email"
        new_column_name = "Email"
      }
    }
    data_transforms {
      rename_column_operation {
        column_name     = "title"
        new_column_name = "Job Title"
      }
    }
    data_transforms {
      rename_column_operation {
        column_name     = "department"
        new_column_name = "Department"
      }
    }
    data_transforms {
      rename_column_operation {
        column_name     = "country"
        new_column_name = "Country"
      }
    }
    data_transforms {
      rename_column_operation {
        column_name     = "employee_number"
        new_column_name = "Employee Number"
      }
    }
    data_transforms {
      rename_column_operation {
        column_name     = "quicksight_role"
        new_column_name = "QuickSight Role"
      }
    }
    data_transforms {
      rename_column_operation {
        column_name     = "license_type"
        new_column_name = "License Type"
      }
    }
    data_transforms {
      rename_column_operation {
        column_name     = "user_tier"
        new_column_name = "User Tier"
      }
    }
    data_transforms {
      rename_column_operation {
        column_name     = "account_created_at"
        new_column_name = "Account Created"
      }
    }
    data_transforms {
      rename_column_operation {
        column_name     = "first_active_at"
        new_column_name = "First Active"
      }
    }
    data_transforms {
      rename_column_operation {
        column_name     = "monthly_agent_hours_allotment"
        new_column_name = "Agent Hours Allotment"
      }
    }
    data_transforms {
      rename_column_operation {
        column_name     = "days_since_last_used_chat"
        new_column_name = "Days Since Last Chat"
      }
    }
    data_transforms {
      rename_column_operation {
        column_name     = "days_since_last_used_agent"
        new_column_name = "Days Since Last Agent Use"
      }
    }
    data_transforms {
      rename_column_operation {
        column_name     = "days_since_last_used"
        new_column_name = "Days Since Last Use"
      }
    }
  }

  permissions {
    actions = [
      "quicksight:DescribeDataSet",
      "quicksight:DescribeDataSetPermissions",
      "quicksight:PassDataSet",
      "quicksight:DescribeIngestion",
      "quicksight:ListIngestions",
      "quicksight:UpdateDataSet",
      "quicksight:DeleteDataSet",
      "quicksight:CreateIngestion",
      "quicksight:CancelIngestion",
      "quicksight:UpdateDataSetPermissions",
    ]
    principal = "arn:aws:quicksight:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:group/${var.quicksight_namespace}/${var.quicksight_admin_group}"
  }

  dynamic "permissions" {
    for_each = local.dashboard_viewer_arns
    content {
      actions = [
        "quicksight:DescribeDataSet",
        "quicksight:DescribeDataSetPermissions",
        "quicksight:PassDataSet",
        "quicksight:DescribeIngestion",
        "quicksight:ListIngestions",
      ]
      principal = permissions.value
    }
  }
}

# SPICE Full Refresh Schedules — Users (daily 1am local, one per region where
# the customer's workforce is concentrated). The custom SQL has no per-row
# watermark column (it recomputes date_diff(..., current_timestamp) for every
# user on every run), so incremental refresh would still scan the full
# message_enriched/agent_hours_enriched tables — full refresh is just as cheap
# and simpler.
resource "aws_quicksight_refresh_schedule" "users_full_sgt" {
  count          = var.spice_enabled ? 1 : 0
  aws_account_id = data.aws_caller_identity.current.account_id
  data_set_id    = aws_quicksight_data_set.users.data_set_id
  schedule_id    = "users-full-refresh-sgt"
  schedule {
    refresh_type = "FULL_REFRESH"
    schedule_frequency {
      interval        = "DAILY"
      time_of_the_day = "01:00"
      timezone        = "Asia/Singapore"
    }
  }
}

resource "aws_quicksight_refresh_schedule" "users_full_uk" {
  count          = var.spice_enabled ? 1 : 0
  aws_account_id = data.aws_caller_identity.current.account_id
  data_set_id    = aws_quicksight_data_set.users.data_set_id
  schedule_id    = "users-full-refresh-uk"
  schedule {
    refresh_type = "FULL_REFRESH"
    schedule_frequency {
      interval        = "DAILY"
      time_of_the_day = "01:00"
      timezone        = "Europe/London"
    }
  }
}

resource "aws_quicksight_refresh_schedule" "users_full_ny" {
  count          = var.spice_enabled ? 1 : 0
  aws_account_id = data.aws_caller_identity.current.account_id
  data_set_id    = aws_quicksight_data_set.users.data_set_id
  schedule_id    = "users-full-refresh-ny"
  schedule {
    refresh_type = "FULL_REFRESH"
    schedule_frequency {
      interval        = "DAILY"
      time_of_the_day = "01:00"
      timezone        = "America/New_York"
    }
  }
}
