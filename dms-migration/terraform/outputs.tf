output "source_instance_id" {
  description = "Instance ID of the on-premises stand-in (Name tag svp-lab-dms-source), the target of the session script's SSM commands."
  value       = module.source_db.instance_id
}

output "source_private_ip" {
  description = "Private IP address of the on-premises PostgreSQL, the host in the source secret."
  value       = module.source_db.private_ip
}

output "target_address" {
  description = "Host of the RDS target svp-lab-dms-target, the host in the target secret."
  value       = module.target_db.address
}

output "replication_task_arn" {
  description = "ARN of the replication task svp-lab-dms, created stopped."
  value       = module.dms.task_arn
}

output "task_log_group" {
  description = "CloudWatch log group of the task logs."
  value       = module.dms.log_group_name
}

output "secret_names" {
  description = "Secrets of the two endpoints. The values are never outputs."
  value = {
    source = module.source_secret.name
    target = module.target_secret.name
  }
}
