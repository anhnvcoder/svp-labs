# What the read side of the view queue guarantees: the table of the contract (key pk, TTL on expires_at, on demand,
# no point-in-time recovery), and a mapping with partial batch responses, batch 100 and window 1 s; no tag of its own.
# The AWS provider is a mock.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "000000000000"
    }
  }
}

variables {
  queue_arn     = "arn:aws:sqs:ap-southeast-1:000000000000:svp-lab-sls-views"
  function_name = "svp-lab-sls-counter"
}

run "table" {
  command = plan

  assert {
    condition = (
      aws_dynamodb_table.views.name == "svp-lab-sls-views" && aws_dynamodb_table.views.billing_mode == "PAY_PER_REQUEST" &&
      aws_dynamodb_table.views.hash_key == "pk" && aws_dynamodb_table.views.range_key == null &&
      [for a in aws_dynamodb_table.views.attribute : { name = a.name, type = a.type }] == [{ name = "pk", type = "S" }]
    )
    error_message = "The table is svp-lab-sls-views, on demand, keyed by pk (string) alone."
  }

  assert {
    condition     = aws_dynamodb_table.views.ttl[0].attribute_name == "expires_at" && aws_dynamodb_table.views.ttl[0].enabled
    error_message = "Dedupe items expire through TTL on expires_at."
  }

  assert {
    condition     = !aws_dynamodb_table.views.point_in_time_recovery[0].enabled
    error_message = "Point-in-time recovery stays off: the lab's data lives one session."
  }

  assert {
    condition     = output.table_arn == "arn:aws:dynamodb:ap-southeast-1:000000000000:table/svp-lab-sls-views"
    error_message = "The table ARN is known at plan, for the counter's role."
  }
}

run "mapping" {
  command = plan

  assert {
    condition = (
      aws_lambda_event_source_mapping.views.event_source_arn == "arn:aws:sqs:ap-southeast-1:000000000000:svp-lab-sls-views" &&
      aws_lambda_event_source_mapping.views.function_name == "svp-lab-sls-counter"
    )
    error_message = "The mapping hands the view queue to the counter."
  }

  assert {
    condition = (
      aws_lambda_event_source_mapping.views.function_response_types == toset(["ReportBatchItemFailures"]) &&
      aws_lambda_event_source_mapping.views.batch_size == 100 &&
      aws_lambda_event_source_mapping.views.maximum_batching_window_in_seconds == 1 &&
      output.batching_window_seconds == 1
    )
    error_message = "Partial batch responses, up to 100 records or 1 s per batch."
  }

  assert {
    condition     = aws_dynamodb_table.views.tags == null && aws_lambda_event_source_mapping.views.tags == null
    error_message = "The module sets no tag: the root's default_tags are the only ones."
  }
}

run "queue_outside_the_lab" {
  command = plan

  variables {
    queue_arn = "arn:aws:sqs:ap-southeast-1:000000000000:svp-stg-transcode-events"
  }

  expect_failures = [var.queue_arn]
}

run "function_outside_the_lab" {
  command = plan

  variables {
    function_name = "svp-engagement"
  }

  expect_failures = [var.function_name]
}
