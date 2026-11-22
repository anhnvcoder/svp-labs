# Plan of dms-migration/terraform on an empty account: neither dms-vpc-role nor dms-cloudwatch-logs-role exists yet,
# so the lab creates both, whatever dms.auto.tfvars.example (for an account that has them) says.

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

variables {
  account_id           = "000000000000"
  rds_ca_bundle        = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
  create_dms_vpc_role  = true
  create_dms_logs_role = true
}

run "inventory" {
  command = plan
}
