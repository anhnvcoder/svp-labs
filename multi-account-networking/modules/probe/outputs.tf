output "instance_id" {
  description = "ID of the instance, the target of a Session Manager session."
  value       = aws_instance.this.id
}

output "instance_arn" {
  description = "ARN of the instance, the form Reachability Analyzer needs for a resource of another account."
  value       = aws_instance.this.arn
}

output "private_ip" {
  description = "Private IPv4 address of the instance."
  value       = aws_instance.this.private_ip
}
