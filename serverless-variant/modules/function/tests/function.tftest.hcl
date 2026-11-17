# What a function of the lab guarantees: arm64 on provided.al2023, a log group with a short retention, a role that
# only Lambda of this account assumes and that writes only its own log group plus the named statements, no tag of its
# own (the root's default_tags tag everything). Then one plan per validation rule. The AWS provider is a mock.

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
  name         = "svp-lab-sls-counter"
  description  = "Counts views"
  package_path = "../../build/counter.zip"
  package_hash = "bm90LWEtcmVhbC1oYXNo"
  timeout      = 30
  environment  = { TABLE_NAME = "svp-lab-sls-views" }
  policy_statements = [{
    sid       = "Table"
    actions   = ["dynamodb:PutItem"]
    resources = ["arn:aws:dynamodb:ap-southeast-1:000000000000:table/svp-lab-sls-views"]
    condition = { "ForAnyValue:StringEquals" = { "dynamodb:EnclosingOperation" = ["TransactWriteItems"] } }
  }]
}

run "function" {
  command = plan

  assert {
    condition = (
      aws_lambda_function.this.architectures == tolist(["arm64"]) && aws_lambda_function.this.runtime == "provided.al2023" &&
      aws_lambda_function.this.handler == "bootstrap" && aws_lambda_function.this.timeout == 30 &&
      aws_lambda_function.this.memory_size == 128
    )
    error_message = "A Go function runs as bootstrap on provided.al2023, arm64, 128 MB, with the given timeout."
  }

  assert {
    condition = (
      aws_lambda_function.this.filename == "../../build/counter.zip" &&
      aws_lambda_function.this.source_code_hash == "bm90LWEtcmVhbC1oYXNo" &&
      aws_lambda_function.this.environment[0].variables == tomap({ TABLE_NAME = "svp-lab-sls-views" })
    )
    error_message = "The function takes the root's package, its hash and the environment as given."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this.name == "/aws/lambda/svp-lab-sls-counter" && aws_cloudwatch_log_group.this.retention_in_days == 1
    error_message = "The log group is the one Lambda writes to, kept one day."
  }

  assert {
    condition = jsondecode(aws_iam_role.this.assume_role_policy).Statement == [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = "000000000000" } }
    }]
    error_message = "Only Lambda, for this account, assumes the role."
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.this.policy).Statement == [
      {
        Sid      = "WriteOwnLogGroup"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:ap-southeast-1:000000000000:log-group:/aws/lambda/svp-lab-sls-counter:*"]
      },
      {
        Sid       = "Table"
        Effect    = "Allow"
        Action    = ["dynamodb:PutItem"]
        Resource  = ["arn:aws:dynamodb:ap-southeast-1:000000000000:table/svp-lab-sls-views"]
        Condition = { "ForAnyValue:StringEquals" = { "dynamodb:EnclosingOperation" = ["TransactWriteItems"] } }
      },
    ]
    error_message = "The role writes its own log group and does what the caller named, nothing more."
  }

  assert {
    condition     = output.arn == "arn:aws:lambda:ap-southeast-1:000000000000:function:svp-lab-sls-counter"
    error_message = "The ARN is known at plan, for the policies of the callers."
  }

  assert {
    condition     = aws_lambda_function.this.tags == null && aws_iam_role.this.tags == null && aws_cloudwatch_log_group.this.tags == null
    error_message = "The module sets no tag: the root's default_tags are the only ones."
  }
}

run "no_environment" {
  command = plan

  variables {
    environment       = {}
    policy_statements = []
  }

  assert {
    condition     = length(aws_lambda_function.this.environment) == 0 && length(jsondecode(aws_iam_role_policy.this.policy).Statement) == 1
    error_message = "Without environment or statements, the function has no environment block and the role only writes its logs."
  }
}

run "name_outside_the_lab" {
  command = plan

  variables {
    name = "svp-engagement"
  }

  expect_failures = [var.name]
}

run "wildcard_action" {
  command = plan

  variables {
    policy_statements = [{ sid = "Any", actions = ["dynamodb:*"], resources = ["arn:aws:dynamodb:ap-southeast-1:000000000000:table/x"] }]
  }

  expect_failures = [var.policy_statements]
}

run "wildcard_resource" {
  command = plan

  variables {
    policy_statements = [{ sid = "Any", actions = ["sqs:SendMessage"], resources = ["*"] }]
  }

  expect_failures = [var.policy_statements]
}

run "fractional_timeout" {
  command = plan

  variables {
    timeout = 2.5
  }

  expect_failures = [var.timeout]
}
