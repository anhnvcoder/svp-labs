# Validation rules of the variables, then the layout the lab relies on: the loader subnet routes to the internet
# gateway, the two data subnets sit in two zones behind a table without any route. The AWS provider is a mock that
# lists the zones out of order.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-southeast-1c", "ap-southeast-1a", "ap-southeast-1b"]
    }
  }
}

variables {
  name       = "svp-lab-ds-pg"
  cidr_block = "10.67.0.0/20"
}

run "layout" {
  command = plan

  assert {
    condition     = aws_vpc.this.cidr_block == "10.67.0.0/20" && aws_vpc.this.enable_dns_support && aws_vpc.this.enable_dns_hostnames
    error_message = "The VPC takes the given range, with DNS support and DNS host names on."
  }

  assert {
    condition     = aws_subnet.public.cidr_block == "10.67.0.0/24" && [for s in aws_subnet.data : s.cidr_block] == ["10.67.1.0/24", "10.67.2.0/24"]
    error_message = "The loader subnet is the first /24 of the VPC and the data subnets the next two."
  }

  assert {
    condition     = [for s in aws_subnet.data : s.availability_zone] == ["ap-southeast-1a", "ap-southeast-1b"]
    error_message = "The data subnets sit in the first two zones by name, whatever order the API lists them in."
  }

  assert {
    condition     = length(toset([for s in aws_subnet.data : s.availability_zone])) == 2
    error_message = "The two data subnets sit in two different zones, as DB and ElastiCache subnet groups require."
  }

  assert {
    condition     = length(aws_route_table.data.route) == 0
    error_message = "The data route table holds no route besides the local one: nothing goes to the internet gateway."
  }

  assert {
    condition     = one([for r in aws_route_table.public.route : r.cidr_block]) == "0.0.0.0/0"
    error_message = "The loader subnet routes everything else to the internet gateway."
  }
}

run "valkey_part" {
  command = plan

  variables {
    name       = "svp-lab-ds-kv"
    cidr_block = "10.67.16.0/20"
  }

  assert {
    condition     = [for s in aws_subnet.data : s.cidr_block] == ["10.67.17.0/24", "10.67.18.0/24"]
    error_message = "The valkey part cuts its own /20 the same way."
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
    cidr_block = "10.67.0.0/16"
  }

  expect_failures = [var.cidr_block]
}

run "cidr_block_not_a_range" {
  command = plan

  variables {
    cidr_block = "10.67.0.0"
  }

  expect_failures = [var.cidr_block]
}
