# Transcode path of the lab: an upload under uploads/ sends Object Created to the default event bus, a rule starts a
# Standard state machine that runs the transcode function, and the result goes out as transcode.completed or
# transcode.failed on the lab's own bus, where a rule copies every event into CloudWatch Logs for inspection.
# Design notes: serverless-variant/README.md.

data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  prefix         = "svp-lab-sls"
  bus_name       = local.prefix
  machine_name   = "${local.prefix}-transcode"
  machine_role   = "${local.machine_name}-machine"
  upload_rule    = "${local.prefix}-upload-created"
  events_rule    = "${local.prefix}-transcode-events"
  machine_log    = "/aws/vendedlogs/states/${local.machine_name}"
  events_log     = "/aws/events/${local.machine_name}"
  event_source   = "svp.lab.transcode"
  upload_prefix  = "uploads/"
  account_id     = data.aws_caller_identity.current.account_id
  account_region = "${data.aws_region.current.region}:${local.account_id}"
  partition      = data.aws_partition.current.partition

  # ARNs are built from their parts rather than read from the resources, so every policy is known at plan.
  bucket_arn      = "arn:${local.partition}:s3:::${var.bucket_name}"
  bus_arn         = "arn:${local.partition}:events:${local.account_region}:event-bus/${local.bus_name}"
  machine_arn     = "arn:${local.partition}:states:${local.account_region}:stateMachine:${local.machine_name}"
  upload_rule_arn = "arn:${local.partition}:events:${local.account_region}:rule/${local.upload_rule}"
  machine_log_arn = "arn:${local.partition}:logs:${local.account_region}:log-group:${local.machine_log}"
  events_log_arn  = "arn:${local.partition}:logs:${local.account_region}:log-group:${local.events_log}"

  # Retries follow the Step Functions advice for transient Lambda service errors. InvalidInput, the error no retry
  # fixes, and any error left after the retries both end in transcode.failed, so a consumer always hears the outcome.
  definition = {
    Comment       = "Transcode of one upload of the serverless-variant lab"
    QueryLanguage = "JSONata"
    StartAt       = "Transcode"
    States = {
      Transcode = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::lambda:invoke"
        Arguments = {
          FunctionName = var.function_arn
          Payload      = { source_key = "{% $states.input.detail.object.key %}" }
        }
        Output = "{% $states.result.Payload %}"
        Retry = [{
          ErrorEquals = [
            "Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException",
            "Lambda.TooManyRequestsException",
          ]
          IntervalSeconds = 2
          MaxAttempts     = 6
          BackoffRate     = 2
        }]
        Catch = [
          {
            ErrorEquals = ["InvalidInput"]
            Next        = "PublishFailed"
            Output = {
              source_key = "{% $states.input.detail.object.key %}"
              error      = "{% $parse($states.errorOutput.Cause).errorMessage %}"
            }
          },
          {
            ErrorEquals = ["States.ALL"]
            Next        = "PublishFailed"
            Output = {
              source_key = "{% $states.input.detail.object.key %}"
              error      = "{% $states.errorOutput.Error %}"
            }
          },
        ]
        Next = "PublishCompleted"
      }
      PublishCompleted = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::events:putEvents"
        Arguments = {
          Entries = [{
            EventBusName = local.bus_name
            Source       = local.event_source
            DetailType   = "transcode.completed"
            Detail       = "{% $states.input %}"
          }]
        }
        End = true
      }
      PublishFailed = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::events:putEvents"
        Arguments = {
          Entries = [{
            EventBusName = local.bus_name
            Source       = local.event_source
            DetailType   = "transcode.failed"
            Detail       = "{% $states.input %}"
          }]
        }
        Next = "Failed"
      }
      Failed = {
        Type  = "Fail"
        Error = "TranscodeFailed"
        Cause = "The upload was not transcoded; see the transcode.failed event."
      }
    }
  }
}

resource "aws_s3_bucket" "uploads" {
  bucket        = var.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# AWS-0132: SSE-S3 instead of a customer managed key: the uploads are throwaway test files, and SSE-KMS would add a
# key and KMS permissions to every reader.
#trivy:ignore:AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "tls_only" {
  bucket = aws_s3_bucket.uploads.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.uploads]
}

# Turned on, S3 sends every event type of the bucket to the default bus; the rule below picks Object Created.
resource "aws_s3_bucket_notification" "uploads" {
  bucket      = aws_s3_bucket.uploads.id
  eventbridge = true
}

resource "aws_cloudwatch_event_bus" "lab" {
  name = local.bus_name
}

resource "aws_cloudwatch_log_group" "machine" {
  name              = local.machine_log
  retention_in_days = 1
}

# Role names are unique in the account, and the transcode function's role already carries the machine's name.
resource "aws_iam_role" "machine" {
  name        = local.machine_role
  description = "State machine ${local.machine_name}: runs the transcode function and publishes its outcome"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = local.machine_arn }
      }
    }]
  })
}

# The log delivery actions take no resource ARN, so Step Functions documents "*" for them; writing the log events is
# limited to the machine's own log group.
resource "aws_iam_role_policy" "machine" {
  name = local.machine_role
  role = aws_iam_role.machine.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeTranscode"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [var.function_arn]
      },
      {
        Sid      = "PublishOutcome"
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = [local.bus_arn]
      },
      {
        Sid    = "LogDelivery"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery", "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries", "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups",
        ]
        Resource = ["*"]
      },
      {
        Sid      = "WriteMachineLog"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["${local.machine_log_arn}:*"]
      },
    ]
  })
}

# Standard, not Express: an upload is rare and slow, Standard keeps each execution's history for inspection and runs
# a step exactly once. Logs carry the execution data (object keys, no secret) so a session can follow each step.
resource "aws_sfn_state_machine" "transcode" {
  name       = local.machine_name
  type       = "STANDARD"
  role_arn   = aws_iam_role.machine.arn
  definition = jsonencode(local.definition)

  logging_configuration {
    log_destination        = "${local.machine_log_arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  depends_on = [aws_iam_role_policy.machine, aws_cloudwatch_log_group.machine]
}

resource "aws_cloudwatch_event_rule" "upload_created" {
  name        = local.upload_rule
  description = "Object Created under ${local.upload_prefix} of ${var.bucket_name}: start a transcode"
  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail = {
      bucket = { name = [var.bucket_name] }
      object = { key = [{ prefix = local.upload_prefix }] }
    }
  })
}

resource "aws_iam_role" "upload_rule" {
  name        = local.upload_rule
  description = "Rule ${local.upload_rule}: starts state machine ${local.machine_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnEquals    = { "aws:SourceArn" = local.upload_rule_arn }
      }
    }]
  })
}

resource "aws_iam_role_policy" "upload_rule" {
  name = local.upload_rule
  role = aws_iam_role.upload_rule.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "StartTranscode"
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = [local.machine_arn]
    }]
  })
}

resource "aws_cloudwatch_event_target" "upload_created" {
  rule     = aws_cloudwatch_event_rule.upload_created.name
  arn      = aws_sfn_state_machine.transcode.arn
  role_arn = aws_iam_role.upload_rule.arn

  depends_on = [aws_iam_role_policy.upload_rule]
}

resource "aws_cloudwatch_log_group" "events" {
  name              = local.events_log
  retention_in_days = 1
}

# EventBridge writes to a CloudWatch Logs target through a resource policy of the account and Region, never a role;
# this one opens only the lab's events log group.
resource "aws_cloudwatch_log_resource_policy" "events" {
  policy_name = local.events_rule
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EventBridgeToLabLog"
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "delivery.logs.amazonaws.com"] }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = ["${local.events_log_arn}:*"]
    }]
  })
}

resource "aws_cloudwatch_event_rule" "transcode_events" {
  name           = local.events_rule
  description    = "Every ${local.event_source} event of bus ${local.bus_name}, copied to ${local.events_log}"
  event_bus_name = aws_cloudwatch_event_bus.lab.name
  event_pattern  = jsonencode({ source = [local.event_source] })
}

resource "aws_cloudwatch_event_target" "transcode_events" {
  rule           = aws_cloudwatch_event_rule.transcode_events.name
  event_bus_name = aws_cloudwatch_event_bus.lab.name
  arn            = local.events_log_arn

  depends_on = [aws_cloudwatch_log_resource_policy.events, aws_cloudwatch_log_group.events]
}
