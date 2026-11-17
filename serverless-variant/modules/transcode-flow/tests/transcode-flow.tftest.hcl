# What the transcode path guarantees: a private upload bucket that sends its events to EventBridge, a rule on Object
# Created under uploads/ that starts a Standard state machine, the machine's retry, catch and the two events of the
# contract on the lab's bus, roles limited to the named resources ("*" only where AWS requires it), and a rule that
# copies the bus's events to CloudWatch Logs; no tag of its own. The AWS provider is a mock.

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
  bucket_name  = "svp-lab-sls-uploads-000000000000-ap-southeast-1"
  function_arn = "arn:aws:lambda:ap-southeast-1:000000000000:function:svp-lab-sls-transcode"
}

run "bucket" {
  command = plan

  assert {
    condition = (
      aws_s3_bucket_public_access_block.uploads.block_public_acls && aws_s3_bucket_public_access_block.uploads.block_public_policy &&
      aws_s3_bucket_public_access_block.uploads.ignore_public_acls && aws_s3_bucket_public_access_block.uploads.restrict_public_buckets
    )
    error_message = "Every public access setting of the upload bucket is blocked."
  }

  assert {
    condition = (
      aws_s3_bucket_ownership_controls.uploads.rule[0].object_ownership == "BucketOwnerEnforced" &&
      one(one(aws_s3_bucket_server_side_encryption_configuration.uploads.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256" &&
      jsondecode(aws_s3_bucket_policy.tls_only.policy).Statement[0].Condition == { Bool = { "aws:SecureTransport" = "false" } }
    )
    error_message = "ACLs are off, objects are encrypted with SSE-S3 and plain HTTP is refused."
  }

  assert {
    condition     = aws_s3_bucket.uploads.force_destroy && aws_s3_bucket_notification.uploads.eventbridge
    error_message = "The bucket sends its events to EventBridge, and the destroy empties it."
  }
}

run "trigger" {
  command = plan

  assert {
    condition = jsondecode(aws_cloudwatch_event_rule.upload_created.event_pattern) == {
      source        = ["aws.s3"]
      "detail-type" = ["Object Created"]
      detail = {
        bucket = { name = ["svp-lab-sls-uploads-000000000000-ap-southeast-1"] }
        object = { key = [{ prefix = "uploads/" }] }
      }
    }
    error_message = "Only Object Created under uploads/ of the upload bucket starts a transcode."
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.upload_rule.policy).Statement == [{
      Sid      = "StartTranscode"
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = ["arn:aws:states:ap-southeast-1:000000000000:stateMachine:svp-lab-sls-transcode"]
    }]
    error_message = "The rule's role only starts the transcode state machine."
  }

  assert {
    condition = jsondecode(aws_iam_role.upload_rule.assume_role_policy).Statement[0].Condition == {
      StringEquals = { "aws:SourceAccount" = "000000000000" }
      ArnEquals    = { "aws:SourceArn" = "arn:aws:events:ap-southeast-1:000000000000:rule/svp-lab-sls-upload-created" }
    }
    error_message = "Only the upload rule of this account assumes the rule's role."
  }
}

run "state_machine" {
  command = plan

  assert {
    condition     = aws_sfn_state_machine.transcode.type == "STANDARD" && jsondecode(aws_sfn_state_machine.transcode.definition).QueryLanguage == "JSONata"
    error_message = "The state machine is a Standard workflow written in JSONata."
  }

  assert {
    condition = jsondecode(aws_sfn_state_machine.transcode.definition).States.Transcode.Arguments == {
      FunctionName = "arn:aws:lambda:ap-southeast-1:000000000000:function:svp-lab-sls-transcode"
      Payload      = { source_key = "{% $states.input.detail.object.key %}" }
    }
    error_message = "The transcode function receives {\"source_key\": <key of the S3 event>}."
  }

  assert {
    condition = (
      jsondecode(aws_sfn_state_machine.transcode.definition).States.Transcode.Retry[0].ErrorEquals == [
        "Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException",
        "Lambda.TooManyRequestsException",
      ] &&
      !contains(jsondecode(aws_sfn_state_machine.transcode.definition).States.Transcode.Retry[0].ErrorEquals, "InvalidInput")
    )
    error_message = "Transient Lambda service errors are retried; InvalidInput is not."
  }

  assert {
    condition = (
      [for c in jsondecode(aws_sfn_state_machine.transcode.definition).States.Transcode.Catch : c.ErrorEquals] ==
      [["InvalidInput"], ["States.ALL"]] &&
      alltrue([for c in jsondecode(aws_sfn_state_machine.transcode.definition).States.Transcode.Catch : c.Next == "PublishFailed"])
    )
    error_message = "InvalidInput, then any error left after the retries, leads to transcode.failed."
  }

  assert {
    condition = (
      jsondecode(aws_sfn_state_machine.transcode.definition).States.PublishCompleted.Arguments.Entries == [{
        EventBusName = "svp-lab-sls", Source = "svp.lab.transcode", DetailType = "transcode.completed", Detail = "{% $states.input %}"
      }] &&
      jsondecode(aws_sfn_state_machine.transcode.definition).States.PublishFailed.Arguments.Entries == [{
        EventBusName = "svp-lab-sls", Source = "svp.lab.transcode", DetailType = "transcode.failed", Detail = "{% $states.input %}"
      }] &&
      jsondecode(aws_sfn_state_machine.transcode.definition).States.Failed.Type == "Fail"
    )
    error_message = "The outcome goes to bus svp-lab-sls as source svp.lab.transcode, and a failed transcode fails the execution."
  }

  assert {
    condition = (
      aws_sfn_state_machine.transcode.logging_configuration[0].level == "ALL" &&
      aws_sfn_state_machine.transcode.logging_configuration[0].log_destination ==
      "arn:aws:logs:ap-southeast-1:000000000000:log-group:/aws/vendedlogs/states/svp-lab-sls-transcode:*" &&
      aws_cloudwatch_log_group.machine.retention_in_days == 1
    )
    error_message = "Every execution logs to the machine's own log group, kept one day."
  }
}

run "machine_role" {
  command = plan

  assert {
    condition = [for s in jsondecode(aws_iam_role_policy.machine.policy).Statement : { sid = s.Sid, action = s.Action, resource = s.Resource }] == [
      {
        sid      = "InvokeTranscode"
        action   = ["lambda:InvokeFunction"]
        resource = ["arn:aws:lambda:ap-southeast-1:000000000000:function:svp-lab-sls-transcode"]
      },
      {
        sid      = "PublishOutcome"
        action   = ["events:PutEvents"]
        resource = ["arn:aws:events:ap-southeast-1:000000000000:event-bus/svp-lab-sls"]
      },
      {
        sid = "LogDelivery"
        action = [
          "logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery", "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries", "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups",
        ]
        resource = ["*"]
      },
      {
        sid      = "WriteMachineLog"
        action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        resource = ["arn:aws:logs:ap-southeast-1:000000000000:log-group:/aws/vendedlogs/states/svp-lab-sls-transcode:*"]
      },
    ]
    error_message = "The machine invokes one function, publishes to one bus and logs to its own log group; only the log delivery actions, which take no ARN, have *."
  }

  assert {
    condition = jsondecode(aws_iam_role.machine.assume_role_policy).Statement[0].Condition == {
      StringEquals = { "aws:SourceAccount" = "000000000000" }
      ArnLike      = { "aws:SourceArn" = "arn:aws:states:ap-southeast-1:000000000000:stateMachine:svp-lab-sls-transcode" }
    }
    error_message = "Only the transcode state machine of this account assumes its role."
  }

  assert {
    condition = (
      aws_iam_role.machine.name == "svp-lab-sls-transcode-machine" &&
      aws_iam_role.machine.name != element(split(":", var.function_arn), 6)
    )
    error_message = "The machine's role has a name of its own: role names are unique in the account, and the function's role carries the function's name."
  }
}

run "event_log" {
  command = plan

  assert {
    condition = (
      aws_cloudwatch_event_rule.transcode_events.event_bus_name == "svp-lab-sls" &&
      jsondecode(aws_cloudwatch_event_rule.transcode_events.event_pattern) == { source = ["svp.lab.transcode"] } &&
      aws_cloudwatch_event_target.transcode_events.arn == "arn:aws:logs:ap-southeast-1:000000000000:log-group:/aws/events/svp-lab-sls-transcode"
    )
    error_message = "Every transcode event of the lab's bus is copied to the events log group."
  }

  assert {
    condition = (
      jsondecode(aws_cloudwatch_log_resource_policy.events.policy_document).Statement[0].Resource ==
      ["arn:aws:logs:ap-southeast-1:000000000000:log-group:/aws/events/svp-lab-sls-transcode:*"] &&
      aws_cloudwatch_log_group.events.retention_in_days == 1
    )
    error_message = "EventBridge may write only to the lab's events log group, kept one day."
  }

  assert {
    condition = (
      aws_s3_bucket.uploads.tags == null && aws_sfn_state_machine.transcode.tags == null &&
      aws_cloudwatch_event_bus.lab.tags == null && aws_iam_role.machine.tags == null
    )
    error_message = "The module sets no tag: the root's default_tags are the only ones."
  }
}

run "bucket_outside_the_lab" {
  command = plan

  variables {
    bucket_name = "svp-stg-uploads-000000000000-ap-southeast-1"
  }

  expect_failures = [var.bucket_name]
}

run "qualified_function" {
  command = plan

  variables {
    function_arn = "arn:aws:lambda:ap-southeast-1:000000000000:function:svp-lab-sls-transcode:live"
  }

  expect_failures = [var.function_arn]
}
