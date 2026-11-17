# Write path of a view: a public REST API whose POST /videos/{id}/views sends one SQS message through an AWS service
# integration, with no Lambda in front, and answers 202. The stage throttles every method to bound the cost of an
# endpoint without authentication. Design notes: serverless-variant/README.md.

data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  name       = "svp-lab-sls-views"
  dlq_name   = "${local.name}-dlq"
  stage_name = "lab"

  region         = data.aws_region.current.region
  account_id     = data.aws_caller_identity.current.account_id
  account_region = "${local.region}:${local.account_id}"
  queue_arn      = "arn:${data.aws_partition.current.partition}:sqs:${local.account_region}:${local.name}"
  dlq_arn        = "arn:${data.aws_partition.current.partition}:sqs:${local.account_region}:${local.dlq_name}"

  # A day covers a session and its analysis; the dead-letter queue keeps the longest SQS allows, since a message
  # moved there keeps its original enqueue time. Five receives give Lambda a few retries before the move.
  message_retention_seconds = 86400
  dlq_retention_seconds     = 1209600
  max_receive_count         = 5

  # Steady rate and bucket size of the stage, in requests per second: enough for the k6 runs of the session, low
  # enough that a stranger who finds the URL spends little. The cost ceiling it implies is in the README.
  throttle_rate_limit  = 50
  throttle_burst_limit = 100

  # Form body of SQS SendMessage. escapeJavaScript keeps the path id inside the JSON string and urlEncode inside its
  # form parameter, so no id can add a JSON field or a form parameter. An id holding ' becomes \', not valid JSON: like
  # any id that is not a UUID it still becomes a message, which the counter refuses until the queue moves it to the
  # dead-letter queue. %7B%22video_id%22%3A%22 is {"video_id":"
  request_template = join("&", [
    "Action=SendMessage",
    "MessageBody=%7B%22video_id%22%3A%22$util.urlEncode($util.escapeJavaScript($input.params('id')))%22%7D",
    "MessageAttribute.1.Name=event_id",
    "MessageAttribute.1.Value.DataType=String",
    "MessageAttribute.1.Value.StringValue=$util.urlEncode($context.requestId)",
  ])
}

resource "aws_sqs_queue" "dlq" {
  name                      = local.dlq_name
  sqs_managed_sse_enabled   = true
  message_retention_seconds = local.dlq_retention_seconds
}

resource "aws_sqs_queue" "main" {
  name                       = local.name
  sqs_managed_sse_enabled    = true
  message_retention_seconds  = local.message_retention_seconds
  visibility_timeout_seconds = var.visibility_timeout_seconds

  redrive_policy = jsonencode({
    deadLetterTargetArn = local.dlq_arn
    maxReceiveCount     = local.max_receive_count
  })

  # SQS refuses a redrive policy whose dead-letter queue does not exist yet.
  depends_on = [aws_sqs_queue.dlq]
}

# Nothing reaches either queue over plain HTTP. The Deny names sqs:* so that an action SQS adds later is refused too;
# a Deny grants nothing.
resource "aws_sqs_queue_policy" "tls_only" {
  for_each = { main = aws_sqs_queue.main.id, dlq = aws_sqs_queue.dlq.id }

  queue_url = each.value
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "sqs:*"
      Resource  = each.key == "main" ? local.queue_arn : local.dlq_arn
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# The role API Gateway assumes for the integration: it sends to the main queue and does nothing else. The trust is the
# one the API Gateway console creates, the service principal alone.
resource "aws_iam_role" "api" {
  name        = "${local.name}-api"
  description = "API Gateway ${local.name}: sends view messages to queue ${local.name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "api" {
  name = "send-views"
  role = aws_iam_role.api.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "SendViews"
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = [local.queue_arn]
    }]
  })
}

resource "aws_api_gateway_rest_api" "this" {
  name        = local.name
  description = "View counter of the serverless-variant lab: POST /videos/{id}/views"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "videos" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "videos"
}

resource "aws_api_gateway_resource" "video" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.videos.id
  path_part   = "{id}"
}

resource "aws_api_gateway_resource" "views" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.video.id
  path_part   = "views"
}

# No authorization, like the anonymous view route of svp: the stage throttle bounds what it costs, and the API lives
# only during a session.
resource "aws_api_gateway_method" "post" {
  rest_api_id        = aws_api_gateway_rest_api.this.id
  resource_id        = aws_api_gateway_resource.views.id
  http_method        = "POST"
  authorization      = "NONE"
  request_parameters = { "method.request.path.id" = true }
}

# A request whose Content-Type has no template is refused with 415 (NEVER) instead of reaching SQS unmapped. A request
# without Content-Type is mapped as application/json.
resource "aws_api_gateway_integration" "sqs" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.views.id
  http_method             = aws_api_gateway_method.post.http_method
  type                    = "AWS"
  integration_http_method = "POST"
  uri                     = "arn:${data.aws_partition.current.partition}:apigateway:${local.region}:sqs:path/${local.account_id}/${local.name}"
  credentials             = aws_iam_role.api.arn
  passthrough_behavior    = "NEVER"
  request_parameters      = { "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'" }
  request_templates       = { "application/json" = local.request_template }
}

resource "aws_api_gateway_method_response" "accepted" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.views.id
  http_method = aws_api_gateway_method.post.http_method
  status_code = "202"
}

resource "aws_api_gateway_method_response" "error" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.views.id
  http_method = aws_api_gateway_method.post.http_method
  status_code = "500"
}

# A 2xx of SQS becomes 202; anything else becomes 500 with a fixed body, so the client never sees the SQS error, which
# names the queue and the account.
resource "aws_api_gateway_integration_response" "accepted" {
  rest_api_id        = aws_api_gateway_rest_api.this.id
  resource_id        = aws_api_gateway_resource.views.id
  http_method        = aws_api_gateway_method.post.http_method
  status_code        = aws_api_gateway_method_response.accepted.status_code
  selection_pattern  = "2\\d{2}"
  response_templates = { "application/json" = "{}" }

  depends_on = [aws_api_gateway_integration.sqs]
}

resource "aws_api_gateway_integration_response" "error" {
  rest_api_id        = aws_api_gateway_rest_api.this.id
  resource_id        = aws_api_gateway_resource.views.id
  http_method        = aws_api_gateway_method.post.http_method
  status_code        = aws_api_gateway_method_response.error.status_code
  response_templates = { "application/json" = "{\"message\":\"view not recorded\"}" }

  depends_on = [aws_api_gateway_integration.sqs]
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  # A change of the route, the integration or the responses needs a new deployment to reach the stage.
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_method.post, aws_api_gateway_integration.sqs,
      aws_api_gateway_integration_response.accepted, aws_api_gateway_integration_response.error,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

# No access log and no X-Ray: access logs need the account-wide CloudWatch role of API Gateway, outside this lab; k6
# measures the latency and the stage's default metrics count the requests.
resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = local.stage_name
}

resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    throttling_rate_limit  = local.throttle_rate_limit
    throttling_burst_limit = local.throttle_burst_limit
  }
}
