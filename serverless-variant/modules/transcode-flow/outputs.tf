output "bucket_name" {
  description = "Name of the upload bucket; uploads go under uploads/."
  value       = aws_s3_bucket.uploads.bucket
}

output "state_machine_arn" {
  description = "ARN of the transcode state machine, known at plan."
  value       = local.machine_arn
}

output "event_bus_name" {
  description = "Bus that receives transcode.completed and transcode.failed."
  value       = aws_cloudwatch_event_bus.lab.name
}

output "events_log_group" {
  description = "Log group holding a copy of every event of the lab's bus."
  value       = aws_cloudwatch_log_group.events.name
}

output "machine_log_group" {
  description = "Log group of the state machine's executions."
  value       = aws_cloudwatch_log_group.machine.name
}
