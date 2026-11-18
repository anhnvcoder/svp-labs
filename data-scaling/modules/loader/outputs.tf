output "instance_id" {
  description = "ID of the instance, the target of SSM send-command."
  value       = aws_instance.this.id
}

output "security_group_id" {
  description = "Security group of the instance; the data tier's security group lets it in on the data ports."
  value       = aws_security_group.this.id
}

output "role_name" {
  description = "Name of the instance's IAM role."
  value       = aws_iam_role.this.name
}
