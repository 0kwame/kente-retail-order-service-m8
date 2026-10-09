# Central log groups. Created here so the instance role never needs
# logs:CreateLogGroup, and so a typo in a name fails at plan time.
#
# No retention_in_days: retention is out of scope for this lab, so the groups
# keep logs forever. Noted in docs/assumptions-log.md as a cost gap.

resource "aws_cloudwatch_log_group" "app" {
  name = "/kente/order-service/app"
}

resource "aws_cloudwatch_log_group" "access" {
  name = "/kente/order-service/access"
}

# The supplied incident logs. scripts/load-sample-logs.sh fills it.
resource "aws_cloudwatch_log_group" "incident" {
  name = "/kente/order-service/incident-2026-07-16"
}
