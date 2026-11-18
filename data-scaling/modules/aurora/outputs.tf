# Read from the writer instance, so that a proxy registers the cluster as its target once it has a writer to route to.
output "cluster_identifier" {
  description = "Identifier of the cluster, the target of RDS Proxy and of failover-db-cluster."
  value       = aws_rds_cluster_instance.writer.cluster_identifier
}

output "endpoint" {
  description = "Writer endpoint of the cluster, which follows the writer through a failover."
  value       = aws_rds_cluster.this.endpoint
}

output "reader_endpoint" {
  description = "Reader endpoint of the cluster, spread over the readers."
  value       = aws_rds_cluster.this.reader_endpoint
}

output "instance_identifiers" {
  description = "Identifiers of the two instances, the writer at creation first."
  value       = [aws_rds_cluster_instance.writer.identifier, aws_rds_cluster_instance.reader.identifier]
}

output "security_group_id" {
  description = "Security group of the cluster, <name>-db; RDS Proxy's group may reach it on 5432."
  value       = aws_security_group.this.id
}
