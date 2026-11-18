output "cme_configuration_endpoint" {
  description = "Configuration endpoint of svp-lab-ds-cme, where a cluster-aware client learns the slots of every shard."
  value       = aws_elasticache_replication_group.cme.configuration_endpoint_address
}

output "cmd_primary_endpoint" {
  description = "Primary endpoint of svp-lab-ds-cmd; through a failover it points at the replica that takes over."
  value       = aws_elasticache_replication_group.cmd.primary_endpoint_address
}

output "secret_name" {
  description = "Name of the secret of the user; the loader's scripts read it at run time."
  value       = aws_secretsmanager_secret.this.name
}

output "secret_arn" {
  description = "ARN of the secret: the loader's role may read it."
  value       = aws_secretsmanager_secret.this.arn
}

output "secret_version_id" {
  description = "Version holding the value written by the last password_version, the one the root reads back for the user."
  value       = aws_secretsmanager_secret_version.this.version_id
}

output "security_group_id" {
  description = "Security group of the nodes of both groups, <name>-valkey."
  value       = aws_security_group.this.id
}
