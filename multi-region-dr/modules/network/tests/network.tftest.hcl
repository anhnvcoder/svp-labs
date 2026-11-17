# Validation rules of the variables, then the layout the lab relies on: the bastion subnet routes to the internet
# gateway, the two database subnets sit in two zones behind a table without any route. The AWS provider is a mock.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
    }
  }
}

variables {
  name       = "svp-lab-dr-primary"
  cidr_block = "10.65.0.0/20"
}

run "layout" {
  command = plan

  assert {
    condition     = aws_vpc.this.enable_dns_support && aws_vpc.this.enable_dns_hostnames
    error_message = "A private hosted zone needs DNS support and DNS host names on in the VPC."
  }

  assert {
    condition     = aws_subnet.public.cidr_block == "10.65.0.0/24" && [for s in aws_subnet.db : s.cidr_block] == ["10.65.1.0/24", "10.65.2.0/24"]
    error_message = "The bastion subnet is the first /24 of the VPC and the database subnets the next two."
  }

  assert {
    condition     = [for s in aws_subnet.db : s.availability_zone] == ["ap-southeast-1a", "ap-southeast-1b"]
    error_message = "The database subnets sit in two availability zones, as an RDS subnet group requires."
  }

  assert {
    condition     = length(aws_route_table.db.route) == 0
    error_message = "The database route table holds no route besides the local one."
  }

  assert {
    condition     = one([for r in aws_route_table.public.route : r.cidr_block]) == "0.0.0.0/0"
    error_message = "The bastion subnet routes everything else to the internet gateway."
  }
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
    cidr_block = "10.65.0.0/16"
  }

  expect_failures = [var.cidr_block]
}

run "cidr_block_not_a_range" {
  command = plan

  variables {
    cidr_block = "10.65.0.0"
  }

  expect_failures = [var.cidr_block]
}
