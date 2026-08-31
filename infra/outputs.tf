output "jenkins_url" {
  description = "Jenkins UI. Reachable only from admin_cidr."
  value       = "http://${aws_instance.jenkins.public_ip}:8080"
}

output "jenkins_public_ip" {
  value = aws_instance.jenkins.public_ip
}

output "target_public_ip" {
  description = "Deploy target. curl this on :80 to see whichever colour is live."
  value       = aws_instance.target.public_ip
}

output "target_private_ip" {
  description = "What the pipeline SSHes to, via DEPLOY_HOST."
  value       = aws_instance.target.private_ip
}

output "service_url" {
  description = "The live service, through the nginx switch."
  value       = "http://${aws_instance.target.public_ip}"
}

output "private_key_path" {
  description = "Lab SSH key. Feeds the kente-deploy-ssh Jenkins credential."
  value       = local_sensitive_file.private_key.filename
}

output "ssh_jenkins" {
  value = "ssh -i ${local_sensitive_file.private_key.filename} ec2-user@${aws_instance.jenkins.public_ip}"
}

output "ssh_target" {
  value = "ssh -i ${local_sensitive_file.private_key.filename} ec2-user@${aws_instance.target.public_ip}"
}
