# Plan of serverless-variant/terraform on an empty account. archive_file is a mock too, so the plan needs no binary
# of make lambda-build: the zip's path and hash are fake values.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
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
      arn        = "arn:aws:sts::000000000000:assumed-role/learner/svp"
    }
  }
}

mock_provider "archive" {
  mock_data "archive_file" {
    defaults = {
      output_base64sha256 = "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
    }
  }
}

variables {
  account_id = "000000000000"
}

run "inventory" {
  command = plan
}
