output "instance_id" {
  description = "ID of the instance, the target of SSM send-command."
  value       = aws_instance.this.id
}

output "private_ip" {
  description = "Private IP address of the instance, the host of the source secret; a new instance has a new one."
  value       = aws_instance.this.private_ip
}

output "security_group_id" {
  description = "Security group of the instance."
  value       = aws_security_group.this.id
}

output "password_parameter_name" {
  description = "Name of the SSM parameter of the DMS user's password. The value is never an output."
  value       = aws_ssm_parameter.password.name
}
