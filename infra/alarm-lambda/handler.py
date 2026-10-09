"""CloudWatch alarm -> SNS -> this function -> Slack incoming webhook.

The webhook is read from Secrets Manager at call time, so it is never in
Terraform, the function configuration or the state file. The value 'none'
turns notifications off, the same convention as the Alertmanager config.
"""
import json
import os
import urllib.request

import boto3


def build_text(alarm):
    state = alarm.get("NewStateValue", "?")
    icon = ":rotating_light:" if state == "ALARM" else ":white_check_mark:"
    return "%s *%s* is %s\n%s" % (
        icon, alarm.get("AlarmName", "?"), state, alarm.get("NewStateReason", ""))


def handler(event, context):
    sid = os.environ["SLACK_SECRET_ID"]
    webhook = boto3.client("secretsmanager").get_secret_value(
        SecretId=sid)["SecretString"].strip()
    if webhook == "none":
        return "slack disabled"
    for record in event["Records"]:
        alarm = json.loads(record["Sns"]["Message"])
        req = urllib.request.Request(
            webhook, data=json.dumps({"text": build_text(alarm)}).encode(),
            headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=5).read()
    return "sent"


if __name__ == "__main__":
    # Self-check: the message text for an ALARM and an OK state.
    a = build_text({"AlarmName": "x", "NewStateValue": "ALARM", "NewStateReason": "r"})
    assert "*x* is ALARM" in a and "rotating_light" in a
    assert "check_mark" in build_text({"AlarmName": "x", "NewStateValue": "OK"})
    print("ok")
