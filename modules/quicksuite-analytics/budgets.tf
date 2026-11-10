# Daily S3 request-cost budget. Catches a LIST-cost regression like the 2026-10 incident, where
# partition projection made every refresh list the whole 2024-2030 prefix range.
# Cost-allocation-tag scoping is unavailable here (account constraint), so the budget is scoped by
# Service + Region + usage-type group "S3: API Requests - Standard". That group is S3 request cost
# only (LIST/GET tiers), excluding storage and data transfer. Verified 2026-11-03 against Cost
# Explorer: this exact filter returned the incident's request cost per account.
# In a shared account the filter also sums other buckets' request cost in the same Region, but their
# baseline is under 0.05 USD/day, so a few-dollar daily limit flags a regression cleanly.
resource "aws_budgets_budget" "s3_requests_daily" {
  count        = var.s3_request_daily_budget_usd != null ? 1 : 0
  name         = "${local.name_prefix}-s3-requests-daily"
  budget_type  = "COST"
  limit_amount = format("%.2f", var.s3_request_daily_budget_usd)
  limit_unit   = "USD"
  time_unit    = "DAILY"

  cost_filter {
    name   = "Service"
    values = ["Amazon Simple Storage Service"]
  }
  cost_filter {
    name   = "Region"
    values = [data.aws_region.current.region]
  }
  cost_filter {
    name   = "UsageTypeGroup"
    values = ["S3: API Requests - Standard"]
  }

  dynamic "notification" {
    for_each = length(var.budget_alert_emails) > 0 ? [1] : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = 100
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.budget_alert_emails
    }
  }
}
