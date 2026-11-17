# Validation rules of the variables, then the two layouts the lab relies on: the on-premises stand-in with one subnet
# routed to an internet gateway, and the AWS side with two subnets in two zones and no route out. The AWS provider is a
# mock.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
    }
  }
}

variables {
  name       = "svp-lab-dms-onprem"
  cidr_block = "192.168.16.0/20"
  subnets    = "public"
}

run "public" {
  command = plan

  assert {
    condition     = length(aws_subnet.this) == 1 && aws_subnet.this[0].cidr_block == "192.168.16.0/24" && aws_subnet.this[0].availability_zone == "ap-southeast-1a"
    error_message = "The on-premises stand-in has one subnet, the first /24 of the VPC, in the first zone."
  }

  assert {
    condition     = length(aws_internet_gateway.this) == 1 && aws_route.internet[0].destination_cidr_block == "0.0.0.0/0"
    error_message = "The public subnet routes to an internet gateway, for the SSM agent and the package repositories."
  }

  assert {
    condition     = aws_vpc.this.enable_dns_support && aws_vpc.this.enable_dns_hostnames
    error_message = "DNS support and DNS host names are on."
  }

  assert {
    condition     = output.availability_zone == "ap-southeast-1a"
    error_message = "The output zone is the zone of the first subnet."
  }
}

run "private" {
  command = plan

  variables {
    name       = "svp-lab-dms-aws"
    cidr_block = "10.66.0.0/20"
    subnets    = "private"
  }

  assert {
    condition     = [for s in aws_subnet.this : s.cidr_block] == ["10.66.0.0/24", "10.66.1.0/24"]
    error_message = "The AWS side has two subnets, the first two /24 of the VPC."
  }

  assert {
    condition     = [for s in aws_subnet.this : s.availability_zone] == ["ap-southeast-1a", "ap-southeast-1b"]
    error_message = "The two subnets sit in two zones, as RDS and DMS subnet groups require."
  }

  assert {
    condition     = length(aws_internet_gateway.this) == 0 && length(aws_route.internet) == 0
    error_message = "The private VPC has no internet gateway and no route out."
  }
}

run "subnets_unknown_kind" {
  command = plan

  variables {
    subnets = "isolated"
  }

  expect_failures = [var.subnets]
}

run "name_outside_the_lab" {
  command = plan

  variables {
    name = "svp-prd"
  }

  expect_failures = [var.name]
}

run "cidr_block_not_a_20" {
  command = plan

  variables {
    cidr_block = "10.66.0.0/16"
  }

  expect_failures = [var.cidr_block]
}
