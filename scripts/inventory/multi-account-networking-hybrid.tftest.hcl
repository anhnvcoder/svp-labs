# Plan of multi-account-networking/hybrid after the root core has applied: the data sources answer with what core
# built (transit gateway, route tables, VPCs, subnets, the probe's security group and instance, the Route 53 Profile)
# as fake ids and CIDRs in the formats the modules validate. One mock per provider alias, each in ap-southeast-1.

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

  mock_data "aws_ec2_transit_gateway" {
    defaults = {
      id = "tgw-00000000000000000"
    }
  }

  mock_data "aws_ec2_transit_gateway_route_table" {
    defaults = {
      id = "tgw-rtb-00000000000000000"
    }
  }

  mock_data "aws_vpc" {
    defaults = {
      id         = "vpc-00000000000000001"
      cidr_block = "10.64.16.0/20"
    }
  }

  mock_data "aws_route53profiles_profiles" {
    defaults = {
      profiles = [{ id = "rp-0000000000000000", arn = "arn:aws:route53profiles:ap-southeast-1:000000000001:profile/rp-0000000000000000", name = "svp-lab-net", share_status = "SHARED_BY_ME" }]
    }
  }
}

mock_provider "aws" {
  alias = "stg"

  mock_data "aws_vpc" {
    defaults = {
      id         = "vpc-00000000000000002"
      cidr_block = "10.64.32.0/20"
    }
  }

  mock_data "aws_subnet" {
    defaults = {
      id = "subnet-00000000000000002"
    }
  }

  mock_data "aws_security_group" {
    defaults = {
      id = "sg-00000000000000002"
    }
  }
}

mock_provider "aws" {
  alias = "prd"

  mock_data "aws_vpc" {
    defaults = {
      id         = "vpc-00000000000000003"
      cidr_block = "10.64.48.0/20"
    }
  }

  mock_data "aws_subnet" {
    defaults = {
      id = "subnet-00000000000000003"
    }
  }

  mock_data "aws_instance" {
    defaults = {
      id = "i-00000000000000003"
    }
  }
}

variables {
  network_account_id = "000000000001"
  stg_account_id     = "000000000002"
  prd_account_id     = "000000000003"
}

run "inventory" {
  command = plan
}
