# What the write path of a view guarantees: POST /videos/{id}/views goes straight to SQS SendMessage with the body and
# the event_id attribute of the contract, escaped; the stage is throttled; the queue redrives to a dead-letter queue
# that keeps messages longer; the API role only sends to that queue; no tag of its own. The AWS provider is a mock.

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
  visibility_timeout_seconds = 181
}

run "route" {
  command = plan

  assert {
    condition = (
      aws_api_gateway_resource.videos.path_part == "videos" && aws_api_gateway_resource.video.path_part == "{id}" &&
      aws_api_gateway_resource.views.path_part == "views" && aws_api_gateway_method.post.http_method == "POST" &&
      aws_api_gateway_method.post.request_parameters == tomap({ "method.request.path.id" = true })
    )
    error_message = "The route is POST /videos/{id}/views with the id from the path."
  }

  assert {
    condition = (
      aws_api_gateway_integration.sqs.type == "AWS" && aws_api_gateway_integration.sqs.integration_http_method == "POST" &&
      aws_api_gateway_integration.sqs.uri == "arn:aws:apigateway:ap-southeast-1:sqs:path/000000000000/svp-lab-sls-views" &&
      aws_api_gateway_integration.sqs.passthrough_behavior == "NEVER"
    )
    error_message = "The integration calls SQS of the main queue directly, never with an unmapped body."
  }

  assert {
    condition = aws_api_gateway_integration.sqs.request_templates["application/json"] == join("&", [
      "Action=SendMessage",
      "MessageBody=%7B%22video_id%22%3A%22$util.urlEncode($util.escapeJavaScript($input.params('id')))%22%7D",
      "MessageAttribute.1.Name=event_id",
      "MessageAttribute.1.Value.DataType=String",
      "MessageAttribute.1.Value.StringValue=$util.urlEncode($context.requestId)",
    ])
    error_message = "The body is {\"video_id\":\"<escaped id>\"} and event_id is the request id, both URL-encoded."
  }

  assert {
    condition = (
      aws_api_gateway_integration_response.accepted.status_code == "202" &&
      aws_api_gateway_integration_response.accepted.selection_pattern == "2\\d{2}" &&
      aws_api_gateway_integration_response.error.status_code == "500" &&
      aws_api_gateway_integration_response.error.selection_pattern == null
    )
    error_message = "A 2xx of SQS answers 202; any other answer is a 500 with a fixed body."
  }

  # The path every method matches, written with join: make test refuses the characters that close a block comment.
  assert {
    condition = (
      aws_api_gateway_method_settings.all.method_path == join("/", ["*", "*"]) &&
      aws_api_gateway_method_settings.all.settings[0].throttling_rate_limit == 50 &&
      aws_api_gateway_method_settings.all.settings[0].throttling_burst_limit == 100
    )
    error_message = "Every method of the stage is throttled at 50 requests per second, burst 100."
  }
}

run "queues" {
  command = plan

  assert {
    condition = jsondecode(aws_sqs_queue.main.redrive_policy) == {
      deadLetterTargetArn = "arn:aws:sqs:ap-southeast-1:000000000000:svp-lab-sls-views-dlq"
      maxReceiveCount     = 5
    }
    error_message = "A message received five times without success moves to the dead-letter queue."
  }

  assert {
    condition = (
      aws_sqs_queue.main.message_retention_seconds == 86400 && aws_sqs_queue.main.visibility_timeout_seconds == 181 &&
      aws_sqs_queue.dlq.message_retention_seconds > aws_sqs_queue.main.message_retention_seconds &&
      output.message_retention_seconds == aws_sqs_queue.main.message_retention_seconds
    )
    error_message = "The main queue keeps a day, with the given visibility timeout; the dead-letter queue keeps longer."
  }

  assert {
    condition     = aws_sqs_queue.main.sqs_managed_sse_enabled && aws_sqs_queue.dlq.sqs_managed_sse_enabled
    error_message = "Both queues are encrypted at rest."
  }

  assert {
    condition = alltrue([for k, p in aws_sqs_queue_policy.tls_only : jsondecode(p.policy).Statement[0].Effect == "Deny" &&
    jsondecode(p.policy).Statement[0].Condition == { Bool = { "aws:SecureTransport" = "false" } }])
    error_message = "Neither queue accepts plain HTTP."
  }
}

run "api_role" {
  command = plan

  assert {
    condition = jsondecode(aws_iam_role_policy.api.policy).Statement == [{
      Sid      = "SendViews"
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = ["arn:aws:sqs:ap-southeast-1:000000000000:svp-lab-sls-views"]
    }]
    error_message = "API Gateway only sends messages to the main queue."
  }

  assert {
    condition     = jsondecode(aws_iam_role.api.assume_role_policy).Statement[0].Principal == { Service = "apigateway.amazonaws.com" }
    error_message = "Only API Gateway assumes the role."
  }

  assert {
    condition = (
      aws_sqs_queue.main.tags == null && aws_sqs_queue.dlq.tags == null && aws_iam_role.api.tags == null &&
      aws_api_gateway_rest_api.this.tags == null && aws_api_gateway_stage.this.tags == null
    )
    error_message = "The module sets no tag: the root's default_tags are the only ones."
  }
}

run "visibility_timeout_too_long" {
  command = plan

  variables {
    visibility_timeout_seconds = 43201
  }

  expect_failures = [var.visibility_timeout_seconds]
}
