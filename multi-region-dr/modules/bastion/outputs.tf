output "instance_id" {
  description = "ID of the instance, the target of SSM send-command."
  value       = aws_instance.this.id
}

output "security_group_id" {
  description = "Security group of the instance; the database lets it in on 5432."
  value       = aws_security_group.this.id
}
