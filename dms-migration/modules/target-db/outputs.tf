output "address" {
  description = "Host name of the instance, the name its TLS certificate carries; the target secret holds it."
  value       = aws_db_instance.this.address
}

output "security_group_id" {
  description = "Security group of the instance."
  value       = aws_security_group.this.id
}
