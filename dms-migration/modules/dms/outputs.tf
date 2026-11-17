output "security_group_id" {
  description = "Security group of the replication instance; the target lets it in on 5432."
  value       = aws_security_group.dms.id
}

output "replication_instance_id" {
  description = "Identifier of the replication instance, a dimension of the DMS metrics in CloudWatch."
  value       = aws_dms_replication_instance.this.replication_instance_id
}

output "task_arn" {
  description = "ARN of the replication task, which the session script starts and the cutover stops."
  value       = aws_dms_replication_task.this.replication_task_arn
}

output "log_group_name" {
  description = "CloudWatch log group of the task logs."
  value       = aws_cloudwatch_log_group.task.name
}
