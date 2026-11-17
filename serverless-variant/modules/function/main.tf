# One Go Lambda function of the serverless-variant lab: arm64 on the OS-only runtime, its execution role and the log
# group it writes to. The role may write only to that log group, plus the statements the caller passes; the root
# packages the binary. Design notes: serverless-variant/README.md.

data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  account_id     = data.aws_caller_identity.current.account_id
  account_region = "${data.aws_region.current.region}:${local.account_id}"

  # ARNs are built from their parts rather than read from the resources, so the callers' policies are known at plan.
  arn            = "arn:${data.aws_partition.current.partition}:lambda:${local.account_region}:function:${var.name}"
  log_group_name = "/aws/lambda/${var.name}"
  log_group_arn  = "arn:${data.aws_partition.current.partition}:logs:${local.account_region}:log-group:${local.log_group_name}"

  logs_statement = {
    Sid      = "WriteOwnLogGroup"
    Effect   = "Allow"
    Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    Resource = ["${local.log_group_arn}:*"]
  }

  caller_statements = [for s in var.policy_statements : merge(
    { Sid = s.sid, Effect = "Allow", Action = s.actions, Resource = s.resources },
    s.condition == null ? {} : { Condition = s.condition },
  )]

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat([local.logs_statement], local.caller_statements)
  })
}

# Created here rather than by Lambda on the first invoke, so it has a retention and the destroy deletes it.
resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_group_name
  retention_in_days = 1
}

resource "aws_iam_role" "this" {
  name        = var.name
  description = "Lambda function ${var.name} of the serverless-variant lab"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "this" {
  name   = var.name
  role   = aws_iam_role.this.id
  policy = local.policy
}

resource "aws_lambda_function" "this" {
  function_name    = var.name
  description      = var.description
  role             = aws_iam_role.this.arn
  architectures    = ["arm64"]
  runtime          = "provided.al2023"
  handler          = "bootstrap"
  filename         = var.package_path
  source_code_hash = var.package_hash
  memory_size      = 128
  timeout          = var.timeout

  dynamic "environment" {
    for_each = length(var.environment) == 0 ? [] : [var.environment]
    content {
      variables = environment.value
    }
  }

  depends_on = [aws_cloudwatch_log_group.this, aws_iam_role_policy.this]
}
