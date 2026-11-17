# svp's view counter and transcode orchestration rebuilt from managed services: API Gateway into SQS, a Go Lambda that
# counts into DynamoDB, and S3 events driving a Step Functions machine that reports on its own EventBridge bus.
# archive_file reads the binaries of make lambda-build at plan, so that build runs first.
# Design notes: serverless-variant/README.md.

locals {
  lab    = "svp-lab-sls"
  region = "ap-southeast-1"

  # The counter's timeout covers a batch of 100 transactions with SDK retries; the queue hides a batch six times
  # that, plus the batching window, so a batch retried after throttling is not delivered twice meanwhile.
  counter_timeout = 30
  visibility      = 6 * local.counter_timeout + module.view_counter.batching_window_seconds

  # A dedupe item must outlive every redelivery of its message: the queue's retention plus a day of margin.
  dedupe_ttl_seconds = module.view_ingest.message_retention_seconds + 86400

  build = "${path.module}/../build"
}

# One fixed mode for every machine, so the zip, and the hash that decides a redeploy, depend on the binary alone.
data "archive_file" "counter" {
  type             = "zip"
  source_file      = "${local.build}/counter/bootstrap"
  output_path      = "${local.build}/counter.zip"
  output_file_mode = "0755"
}

data "archive_file" "transcode" {
  type             = "zip"
  source_file      = "${local.build}/transcode/bootstrap"
  output_path      = "${local.build}/transcode.zip"
  output_file_mode = "0755"
}

module "view_ingest" {
  source = "../modules/view-ingest"

  visibility_timeout_seconds = local.visibility
}

module "view_counter" {
  source = "../modules/view-counter"

  queue_arn     = module.view_ingest.queue_arn
  function_name = module.counter.name
}

module "counter" {
  source = "../modules/function"

  name         = "${local.lab}-counter"
  description  = "Counts views from queue svp-lab-sls-views into table svp-lab-sls-views, once per event_id"
  package_path = data.archive_file.counter.output_path
  package_hash = data.archive_file.counter.output_base64sha256
  timeout      = local.counter_timeout
  environment = {
    TABLE_NAME         = module.view_counter.table_name
    DEDUPE_TTL_SECONDS = tostring(local.dedupe_ttl_seconds)
  }
  policy_statements = [
    {
      sid       = "ReadViewQueue"
      actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
      resources = [module.view_ingest.queue_arn]
    },
    {
      # Only inside TransactWriteItems: the dedupe put and the counter update are never written alone. ForAnyValue,
      # not ForAllValues, which would also match a plain PutItem that carries no enclosing operation.
      sid       = "CountInTransactions"
      actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
      resources = [module.view_counter.table_arn]
      condition = { "ForAnyValue:StringEquals" = { "dynamodb:EnclosingOperation" = ["TransactWriteItems"] } }
    },
  ]
}

module "transcode" {
  source = "../modules/function"

  name         = "${local.lab}-transcode"
  description  = "Transcode step of state machine svp-lab-sls-transcode: checks the upload key, returns the playlist key"
  package_path = data.archive_file.transcode.output_path
  package_hash = data.archive_file.transcode.output_base64sha256
  timeout      = 10
}

module "transcode_flow" {
  source = "../modules/transcode-flow"

  bucket_name  = "${local.lab}-uploads-${var.account_id}-${local.region}"
  function_arn = module.transcode.arn
}
