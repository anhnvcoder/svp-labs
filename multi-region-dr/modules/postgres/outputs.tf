output "arn" {
  description = "ARN of the DB instance; a replica in another Region and the backup replication name the primary by it."
  value       = aws_db_instance.this.arn
}

output "address" {
  description = "Host name of the instance, the name its TLS certificate carries; db.<zone> is a CNAME to it."
  value       = aws_db_instance.this.address
}

output "security_group_id" {
  description = "Security group of the instance, <name>-db."
  value       = aws_security_group.this.id
}

output "replicated_backups_arn" {
  description = "ARN of the automated backups replicated into this Region, the source of a point-in-time restore there; null unless replicate_backups is true."
  value       = one(aws_db_instance_automated_backups_replication.this[*].id)
}
