output "loader_instance_id" {
  description = "Instance ID of the loader svp-lab-ds-pg-loader, the target of the session script's SSM commands."
  value       = module.loader.instance_id
}

output "aurora_endpoints" {
  description = "Writer and reader endpoints of svp-lab-ds-aurora; null when aurora = false."
  value       = var.aurora ? { writer = module.aurora[0].endpoint, reader = module.aurora[0].reader_endpoint } : null
}

output "rds_addresses" {
  description = "Hosts of the RDS primary svp-lab-ds-rds and its replica; null when rds = false."
  value       = var.rds ? { primary = module.rds[0].primary_address, replica = module.rds[0].replica_address } : null
}

output "proxy_endpoint" {
  description = "Endpoint of svp-lab-ds-proxy; null when proxy = false."
  value       = var.proxy ? module.rds_proxy[0].endpoint : null
}

output "secret_name" {
  description = "Secret of the master user, read by the loader and the proxy. The value is never an output."
  value       = module.db_secret.name
}
