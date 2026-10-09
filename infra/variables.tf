variable "region" {
  description = "AWS region for the lab."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for every resource name and tag."
  type        = string
  default     = "kente-cicd"
}

variable "instance_type" {
  description = "Instance type for both hosts. t3.small is the floor for Jenkins + a Maven build."
  type        = string
  default     = "t3.small"
}

variable "target_instance_type" {
  description = "Deploy target. Runs two app colours plus Prometheus, Alertmanager and Grafana, so it needs more memory than the 2 GB of a t3.small."
  type        = string
  default     = "t3.medium"
}

variable "admin_cidr" {
  description = <<-DESC
    The only CIDR allowed to reach SSH and the Jenkins UI. Pass your own address:
      -var "admin_cidr=$(curl -s https://checkip.amazonaws.com)/32"
    Deliberately has no default -- a default here would be 0.0.0.0/0, and an
    internet-exposed Jenkins is a finding, not a convenience.
  DESC
  type        = string

  validation {
    condition     = var.admin_cidr != "0.0.0.0/0"
    error_message = "Refusing to open SSH and Jenkins to the whole internet. Pass your own /32."
  }
}

variable "repo_url" {
  description = <<-DESC
    Public HTTPS clone URL. Both hosts clone it in user_data to get their own
    bootstrap scripts, with no credentials -- so this repository must be public.
    If it is ever made private, user_data needs a deploy key or a PAT and the
    clone stops being the simple thing it is today.
  DESC
  type        = string
  default     = "https://github.com/0kwame/kente-retail-order-service-m8.git"
}

variable "repo_branch" {
  description = "Branch the hosts bootstrap from."
  type        = string
  default     = "main"
}

# jenkins_admin_password and slack_webhook_url were variables in Module 7.
# They are now Secrets Manager secrets filled by scripts/set-secrets.sh, so a
# secret value is never passed to Terraform and never lands in its state.
