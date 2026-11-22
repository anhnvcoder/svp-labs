# Plan of data-scaling/postgres on an empty account with the parts of postgres.auto.tfvars.example (Aurora, RDS and
# RDS Proxy); the zones of the data subnets and the newest Aurora minor version are fake values.

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

  mock_data "aws_subnet" {
    defaults = {
      availability_zone = "ap-southeast-1a"
    }
  }

  mock_data "aws_rds_engine_version" {
    defaults = {
      version        = "17.5"
      version_actual = "17.5"
    }
  }

  mock_data "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:ap-southeast-1:000000000000:key/00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  account_id = "000000000000"
}

run "inventory" {
  command = plan
}
