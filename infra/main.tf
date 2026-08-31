# Kente Retail CI/CD lab -- two hosts, default VPC, no new networking.
#
# Topology and why:
#   jenkins-host   runs Jenkins in a container it builds itself (docker CLI,
#                  Maven and Trivy baked in). Separate from the deploy target so
#                  a bad deploy cannot take out the pipeline that would fix it.
#   deploy-target  runs nginx on :80 plus two order-service containers on
#                  127.0.0.1:8081 (blue) and :8082 (green). The colour ports are
#                  bound to loopback, so the only way in from outside is nginx.
#
# Neither host holds a long-lived credential it did not need: the deploy key is
# generated here, handed to Jenkins once by scripts/bootstrap-jenkins.sh, and
# never written into user_data (which is readable by anything that can reach the
# instance metadata service).

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 5.0" }
    tls   = { source = "hashicorp/tls", version = "~> 4.0" }
    local = { source = "hashicorp/local", version = "~> 2.4" }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "kente-retail-cicd"
      Module    = "07-cicd"
      ManagedBy = "terraform"
    }
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# One keypair for the lab. Terraform generates it so the private key that
# Jenkins will use to reach the deploy target never has to be created by hand
# or reused from another module.
resource "tls_private_key" "lab" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "lab" {
  key_name   = "${var.name_prefix}-key"
  public_key = tls_private_key.lab.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  filename        = "${path.module}/${var.name_prefix}-key.pem"
  content         = tls_private_key.lab.private_key_pem
  file_permission = "0600"
}

resource "aws_security_group" "jenkins" {
  name        = "${var.name_prefix}-jenkins"
  description = "Jenkins host: SSH and UI from the admin CIDR only."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH from admin"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "Jenkins UI from admin"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    description = "Outbound for package installs, plugin downloads and Trivy DB updates"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-jenkins" }
}

resource "aws_security_group" "target" {
  name        = "${var.name_prefix}-target"
  description = "Deploy target: SSH from Jenkins, HTTP from Jenkins and admin. Colour ports stay on loopback."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "SSH from the Jenkins host (this is how the pipeline deploys)"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.jenkins.id]
  }

  ingress {
    description = "SSH from admin, for the walkthrough and incident response"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description     = "HTTP from the Jenkins host, for post-switch smoke tests"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.jenkins.id]
  }

  ingress {
    description = "HTTP from admin, to demonstrate the switch and rollback live"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-target" }
}

resource "aws_instance" "target" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  key_name                    = aws_key_pair.lab.key_name
  vpc_security_group_ids      = [aws_security_group.target.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data_target.sh", {
    repo_url    = var.repo_url
    repo_branch = var.repo_branch
  })

  tags = { Name = "${var.name_prefix}-target", Role = "deploy-target" }
}

resource "aws_instance" "jenkins" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  key_name                    = aws_key_pair.lab.key_name
  vpc_security_group_ids      = [aws_security_group.jenkins.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data_jenkins.sh", {
    repo_url               = var.repo_url
    repo_branch            = var.repo_branch
    jenkins_admin_password = var.jenkins_admin_password
    slack_webhook_url      = var.slack_webhook_url
    deploy_host            = aws_instance.target.private_ip
  })

  tags = { Name = "${var.name_prefix}-jenkins", Role = "jenkins" }
}
