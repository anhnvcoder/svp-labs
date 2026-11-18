output "primary_identifier" {
  description = "Identifier of the Multi-AZ primary, the target of reboot-db-instance with failover."
  value       = aws_db_instance.primary.identifier
}

output "primary_address" {
  description = "Host of the primary; through a failover it points at the standby that takes over."
  value       = aws_db_instance.primary.address
}

output "replica_identifier" {
  description = "Identifier of the read replica."
  value       = aws_db_instance.replica.identifier
}

output "replica_address" {
  description = "Host of the read replica."
  value       = aws_db_instance.replica.address
}

output "security_group_id" {
  description = "Security group of the primary and the replica, <name>-db."
  value       = aws_security_group.this.id
}
