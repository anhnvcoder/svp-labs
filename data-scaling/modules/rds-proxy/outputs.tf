output "name" {
  description = "Name of the proxy, the ProxyName dimension of its CloudWatch metrics."
  value       = aws_db_proxy.this.name
}

output "endpoint" {
  description = "Default endpoint of the proxy, routed to the cluster's writer."
  value       = aws_db_proxy.this.endpoint
}

output "security_group_id" {
  description = "Security group of the proxy; the cluster's group lets it in on 5432."
  value       = aws_security_group.this.id
}
