# Created EMPTY. The value is put in with the AWS CLI, so it never appears in a
# .tf file, a tfvars file, user_data or terraform.tfstate.
# recovery_window_in_days = 0 lets a lab teardown delete it at once.
resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.name_prefix}/order-service/db-password"
  description             = "order-service DB password. Replaces the plaintext value that leaked via /actuator/env."
  recovery_window_in_days = 0
}


# --- deploy target instance role --------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "target" {
  name               = "${var.name_prefix}-target"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "target" {
  # bluegreen.sh reads the DB password at deploy time. One secret, read-only.
  # No kms:Decrypt: the secret uses the AWS-managed key, whose key policy
  # already allows use through Secrets Manager for principals in this account.
  statement {
    sid       = "ReadDbPassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db_password.arn]
  }
}

resource "aws_iam_role_policy" "target" {
  name   = "${var.name_prefix}-target"
  role   = aws_iam_role.target.id
  policy = data.aws_iam_policy_document.target.json
}

resource "aws_iam_instance_profile" "target" {
  name = "${var.name_prefix}-target"
  role = aws_iam_role.target.name
}
