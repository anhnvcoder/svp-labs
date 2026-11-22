# Plan of data-scaling/valkey on an empty account with the shard count of valkey.auto.tfvars.example.

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
}

variables {
  account_id = "000000000000"
}

run "inventory" {
  command = plan
}
