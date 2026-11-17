# Read side of the view queue: the table that holds the counters and the dedupe items, and the event source mapping
# that hands batches of the queue to the counter function. Design notes: serverless-variant/README.md.

data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  table_name = "svp-lab-sls-views"
  table_arn  = "arn:${data.aws_partition.current.partition}:dynamodb:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${local.table_name}"

  # Up to 100 records or 1 s, whichever comes first: the counter waits at most as long as svp's batch consumer does,
  # and a busy queue takes a hundredth of the invocations of one record each.
  batch_size              = 100
  batching_window_seconds = 1
}

# On demand: billed per request, nothing while idle. Dedupe items expire through TTL, which deletes without consuming
# write capacity. No point-in-time recovery, which costs per GB-month for a table the destroy drops.
resource "aws_dynamodb_table" "views" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = false
  }
}

# A record the function reports as failed goes back to the queue alone; the others of its batch are deleted.
resource "aws_lambda_event_source_mapping" "views" {
  event_source_arn                   = var.queue_arn
  function_name                      = var.function_name
  batch_size                         = local.batch_size
  maximum_batching_window_in_seconds = local.batching_window_seconds
  function_response_types            = ["ReportBatchItemFailures"]
}
