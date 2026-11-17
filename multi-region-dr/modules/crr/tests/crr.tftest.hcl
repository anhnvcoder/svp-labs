# Validation rules of the variables, then the replication the lab measures: every object, delete markers included, no
# Replication Time Control, and a role limited to the actions of the S3 replication guide on the two buckets. The
# AWS provider is a mock.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
}

variables {
  name                   = "svp-lab-dr-media-replication"
  source_bucket_name     = "svp-lab-dr-media-000000000000-ap-southeast-1"
  destination_bucket_arn = "arn:aws:s3:::svp-lab-dr-media-000000000000-us-east-1"
}

run "replication" {
  command = plan

  assert {
    condition     = aws_s3_bucket_replication_configuration.this.rule[0].status == "Enabled" && aws_s3_bucket_replication_configuration.this.rule[0].delete_marker_replication[0].status == "Enabled"
    error_message = "One enabled rule replicates objects and delete markers."
  }

  assert {
    condition     = aws_s3_bucket_replication_configuration.this.rule[0].destination[0].bucket == var.destination_bucket_arn && length(aws_s3_bucket_replication_configuration.this.rule[0].destination[0].replication_time) == 0
    error_message = "Objects go to the DR bucket, without Replication Time Control."
  }

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Principal.Service == "s3.amazonaws.com"
    error_message = "Only S3 assumes the role."
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.this.policy).Statement == [
      { Sid = "ReadReplicationConfiguration", Effect = "Allow", Action = ["s3:GetReplicationConfiguration", "s3:ListBucket"], Resource = "arn:aws:s3:::svp-lab-dr-media-000000000000-ap-southeast-1" },
      { Sid = "ReadSourceVersions", Effect = "Allow", Action = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"], Resource = "arn:aws:s3:::svp-lab-dr-media-000000000000-ap-southeast-1/*" },
      { Sid = "WriteReplicas", Effect = "Allow", Action = ["s3:ReplicateObject", "s3:ReplicateDelete"], Resource = "arn:aws:s3:::svp-lab-dr-media-000000000000-us-east-1/*" },
    ]
    error_message = "The role reads the source and writes replicas, nothing else."
  }
}

run "name_outside_the_lab" {
  command = plan

  variables {
    name = "svp-media-replication"
  }

  expect_failures = [var.name]
}

run "source_bucket_outside_the_lab" {
  command = plan

  variables {
    source_bucket_name = "svp-prd-media-000000000000-ap-southeast-1"
  }

  expect_failures = [var.source_bucket_name]
}

run "destination_given_a_name" {
  command = plan

  variables {
    destination_bucket_arn = "svp-lab-dr-media-000000000000-us-east-1"
  }

  expect_failures = [var.destination_bucket_arn]
}
