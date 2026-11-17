output "view_url" {
  description = "Public view route; replace {id} with a video id and POST it."
  value       = module.view_ingest.invoke_url
}

output "view_queue_url" {
  description = "URL of queue svp-lab-sls-views, for the duplicate test that sends the same message twice."
  value       = module.view_ingest.queue_url
}

output "view_dlq_url" {
  description = "URL of the dead-letter queue svp-lab-sls-views-dlq."
  value       = module.view_ingest.dlq_url
}

output "views_table" {
  description = "DynamoDB table of the counters and dedupe items."
  value       = module.view_counter.table_name
}

output "upload_bucket" {
  description = "Upload bucket; an object under uploads/ starts a transcode."
  value       = module.transcode_flow.bucket_name
}

output "state_machine_arn" {
  description = "ARN of the transcode state machine."
  value       = module.transcode_flow.state_machine_arn
}

output "events_log_group" {
  description = "Log group holding every transcode.completed and transcode.failed event."
  value       = module.transcode_flow.events_log_group
}
