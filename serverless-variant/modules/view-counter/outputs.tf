output "table_name" {
  description = "Name of the views table."
  value       = aws_dynamodb_table.views.name
}

output "table_arn" {
  description = "ARN of the views table, known at plan."
  value       = local.table_arn
}

output "batching_window_seconds" {
  description = "Batching window of the event source mapping, part of the queue's visibility timeout."
  value       = local.batching_window_seconds
}
