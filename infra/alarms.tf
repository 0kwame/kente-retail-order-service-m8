# Two alarms on the nginx access log, delivered to the same Slack channel as the
# Prometheus alerts. CloudWatch cannot post to a Slack webhook, so the path is
# alarm -> SNS topic -> small Lambda -> webhook.

# 1. Any request for /actuator reaching nginx. nginx answers 403, but the
#    attempt is the signal. Prometheus scrapes the app on loopback and never goes
#    through nginx, so a legitimate request cannot trip this.
resource "aws_cloudwatch_log_metric_filter" "actuator_probe" {
  name           = "${var.name_prefix}-actuator-probe"
  log_group_name = aws_cloudwatch_log_group.access.name
  pattern        = "\"/actuator\""
  metric_transformation {
    name          = "ActuatorProbes"
    namespace     = "Kente/OrderService"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "actuator_probe" {
  alarm_name          = "${var.name_prefix}-actuator-probe"
  alarm_description   = "A request for /actuator/* reached nginx. See docs/queries/incident-probes.logsinsights."
  namespace           = "Kente/OrderService"
  metric_name         = "ActuatorProbes"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

# 2. A burst of 404s: a scanner walking paths. The access log is plain text, and
#    a metric filter can only split a count by IP on JSON logs, so this counts all
#    404s, not one IP. At this traffic level a scan stands out in the total.
resource "aws_cloudwatch_log_metric_filter" "not_found" {
  name           = "${var.name_prefix}-404"
  log_group_name = aws_cloudwatch_log_group.access.name
  pattern        = "\"\\\" 404 \""
  metric_transformation {
    name          = "NotFound"
    namespace     = "Kente/OrderService"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "not_found" {
  alarm_name          = "${var.name_prefix}-404-burst"
  alarm_description   = "20 or more 404s in one minute. Likely a path scan."
  namespace           = "Kente/OrderService"
  metric_name         = "NotFound"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 20
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

# --- delivery -----------------------------------------------------------------

resource "aws_sns_topic" "alarms" {
  name = "${var.name_prefix}-alarms"
}

data "archive_file" "alarm_lambda" {
  type        = "zip"
  source_file = "${path.module}/alarm-lambda/handler.py"
  output_path = "${path.module}/alarm-lambda/handler.zip"
}

resource "aws_cloudwatch_log_group" "alarm_lambda" {
  name              = "/aws/lambda/${var.name_prefix}-alarm-to-slack"
  retention_in_days = 14
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alarm_lambda" {
  name               = "${var.name_prefix}-alarm-to-slack"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "alarm_lambda" {
  statement {
    sid       = "ReadSlackWebhook"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.slack_webhook.arn]
  }
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.alarm_lambda.arn}:*"]
  }
}

resource "aws_iam_role_policy" "alarm_lambda" {
  name   = "${var.name_prefix}-alarm-to-slack"
  role   = aws_iam_role.alarm_lambda.id
  policy = data.aws_iam_policy_document.alarm_lambda.json
}

resource "aws_lambda_function" "alarm_to_slack" {
  function_name    = "${var.name_prefix}-alarm-to-slack"
  role             = aws_iam_role.alarm_lambda.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.alarm_lambda.output_path
  source_code_hash = data.archive_file.alarm_lambda.output_base64sha256
  timeout          = 10
  environment {
    variables = { SLACK_SECRET_ID = aws_secretsmanager_secret.slack_webhook.name }
  }
  depends_on = [aws_cloudwatch_log_group.alarm_lambda]
}

resource "aws_lambda_permission" "sns" {
  statement_id  = "AllowSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.alarm_to_slack.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alarms.arn
}

resource "aws_sns_topic_subscription" "slack" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.alarm_to_slack.arn
}
