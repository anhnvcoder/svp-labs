output "invoke_url" {
  description = "URL of the view route with {id} left for the client: POST it to record one view."
  value       = "${aws_api_gateway_stage.this.invoke_url}/videos/{id}/views"
}

output "queue_arn" {
  description = "ARN of the main queue, known at plan."
  value       = local.queue_arn
}

output "queue_url" {
  description = "URL of the main queue."
  value       = aws_sqs_queue.main.url
}

output "dlq_url" {
  description = "URL of the dead-letter queue."
  value       = aws_sqs_queue.dlq.url
}

output "message_retention_seconds" {
  description = "Retention of the main queue: the longest a message can still be delivered, which the counter's dedupe items must outlast."
  value       = local.message_retention_seconds
}
