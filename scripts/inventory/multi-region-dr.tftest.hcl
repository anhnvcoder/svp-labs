# Plan of multi-region-dr/terraform on an empty account in both Regions: ap-southeast-1 (primary) and us-east-1 (DR),
# each with three zones; the AWS managed key aws/rds of us-east-1 answers with a fake ARN.

mock_provider "aws" {
  alias = "primary"

  mock_resource "aws_db_instance" {
    defaults = {
      arn = "arn:aws:rds:ap-southeast-1:000000000000:db:svp-lab-dr-primary"
    }
  }

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

  mock_data "aws_availability_zones" {
    defaults = {
      names    = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
      zone_ids = ["apse1-az1", "apse1-az2", "apse1-az3"]
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-00000000000000000"
    }
  }
}

mock_provider "aws" {
  alias = "dr"

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names    = ["us-east-1a", "us-east-1b", "us-east-1c"]
      zone_ids = ["use1-az1", "use1-az2", "use1-az3"]
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-00000000000000000"
    }
  }

  mock_data "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-east-1:000000000000:key/00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  account_id = "000000000000"
}

run "inventory" {
  command = plan
}
