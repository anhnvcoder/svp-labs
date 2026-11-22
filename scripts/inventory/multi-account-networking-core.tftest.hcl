# Plan of multi-account-networking/core on four accounts (management, svp-network, svp-stg, svp-prd) that hold nothing
# of the lab yet: one mock per provider alias, each in ap-southeast-1.

mock_provider "aws" {
  alias = "management"

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-00000000000000000"
    }
  }
}

mock_provider "aws" {
  alias = "network"

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-00000000000000000"
    }
  }
}

mock_provider "aws" {
  alias = "stg"

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-00000000000000000"
    }
  }
}

mock_provider "aws" {
  alias = "prd"

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-00000000000000000"
    }
  }
}

variables {
  management_account_id = "000000000000"
  network_account_id    = "000000000001"
  stg_account_id        = "000000000002"
  prd_account_id        = "000000000003"
}

run "inventory" {
  command = plan
}
