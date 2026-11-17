# The egress VPC with the values of the lab: its subnets, the next hop of every route and its single NAT gateway;
# then one plan per validation rule. The AWS provider is a mock: nothing reaches an account. Gateway ids exist only
# after apply, so the routes are read from the module's locals.

mock_provider "aws" {}

variables {
  name                 = "svp-lab-net-egress"
  cidr                 = "10.64.0.0/20"
  spokes_cidr          = "10.64.0.0/16"
  availability_zone_id = "apse1-az1"
  transit_gateway_id   = "tgw-0123456789abcdef0"
}

run "egress" {
  command = plan

  assert {
    condition = (aws_subnet.this["public"].cidr_block == "10.64.0.0/24" &&
      aws_subnet.this["tgw"].cidr_block == "10.64.1.0/28" &&
    aws_subnet.this["probe"].cidr_block == "10.64.2.0/24")
    error_message = "Unexpected subnet ranges."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.this : s.map_public_ip_on_launch == false])
    error_message = "No subnet may give a public address by itself: only the NAT gateway has one, explicitly."
  }

  assert {
    condition = local.routes == {
      "public|0.0.0.0/0"    = "igw"
      "public|10.64.0.0/16" = "tgw"
      "tgw|0.0.0.0/0"       = "nat"
      "probe|0.0.0.0/0"     = "nat"
      "probe|10.64.0.0/16"  = "tgw"
    }
    error_message = "Spoke traffic must go tgw subnet -> NAT -> internet gateway and come back through the transit gateway."
  }

  assert {
    condition     = length(aws_route.this) == 5 && alltrue([for k, r in aws_route.this : r.destination_cidr_block == split("|", k)[1]])
    error_message = "Each route of local.routes must exist with its destination."
  }

  assert {
    condition = (aws_route.this["public|10.64.0.0/16"].transit_gateway_id == "tgw-0123456789abcdef0" &&
    aws_route.this["probe|10.64.0.0/16"].transit_gateway_id == "tgw-0123456789abcdef0")
    error_message = "The return routes must point at the given transit gateway."
  }

  assert {
    condition     = aws_nat_gateway.this.connectivity_type == "public" && aws_eip.nat.domain == "vpc"
    error_message = "The lab's single NAT gateway must be public, with its own Elastic IP."
  }

  assert {
    condition = (aws_ec2_transit_gateway_vpc_attachment.this.transit_gateway_default_route_table_association == false &&
    aws_ec2_transit_gateway_vpc_attachment.this.transit_gateway_default_route_table_propagation == false)
    error_message = "The attachment must join no default route table."
  }
}

run "spokes_cidr_default" {
  command = plan

  variables {
    spokes_cidr = "0.0.0.0/0"
  }

  expect_failures = [var.spokes_cidr]
}

run "cidr_too_small" {
  command = plan

  variables {
    cidr = "10.64.0.0/24"
  }

  expect_failures = [var.cidr]
}

run "zone_name_instead_of_id" {
  command = plan

  variables {
    availability_zone_id = "ap-southeast-1a"
  }

  expect_failures = [var.availability_zone_id]
}

run "transit_gateway_id_invalid" {
  command = plan

  variables {
    transit_gateway_id = "igw-0123"
  }

  expect_failures = [var.transit_gateway_id]
}
