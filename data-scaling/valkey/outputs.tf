output "loader_instance_id" {
  description = "Instance ID of the loader svp-lab-ds-kv-loader, the target of the session script's SSM commands."
  value       = module.loader.instance_id
}

output "cme_configuration_endpoint" {
  description = "Configuration endpoint of svp-lab-ds-cme (cluster mode enabled)."
  value       = module.valkey.cme_configuration_endpoint
}

output "cmd_primary_endpoint" {
  description = "Primary endpoint of svp-lab-ds-cmd (cluster mode disabled)."
  value       = module.valkey.cmd_primary_endpoint
}

output "secret_name" {
  description = "Secret of the Valkey user, read by the loader. The value is never an output."
  value       = module.valkey.secret_name
}
