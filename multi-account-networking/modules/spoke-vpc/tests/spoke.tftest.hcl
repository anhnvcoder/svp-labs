# A spoke with the values of stg: its subnets, its only route out and its attachment; then the owner's attachment and
# one plan per validation rule. The AWS provider is a mock: nothing reaches an account.

mock_provider "aws" {}

variables {
  name                            = "svp-lab-net-stg"
  cidr                            = "10.64.32.0/20"
  availability_zone_id            = "apse1-az1"
  transit_gateway_id              = "tgw-0123456789abcdef0"
  transit_gateway_in_same_account = false
}

run "spoke" {
  command = plan

  assert {
    condition = (aws_subnet.this["workload"].cidr_block == "10.64.32.0/24" &&
    aws_subnet.this["tgw"].cidr_block == "10.64.33.0/28")
    error_message = "The workload subnet must be the first /24 and the attachment subnet the /28 after it."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.this : s.availability_zone_id == "apse1-az1" && s.map_public_ip_on_launch == false])
    error_message = "Both subnets must sit in the given zone ID and give no public address."
  }

  assert {
    condition     = aws_vpc.this.enable_dns_support && aws_vpc.this.enable_dns_hostnames
    error_message = "Both DNS attributes must be on, or the private hosted zones do not answer."
  }

  assert {
    condition = (aws_route.workload_default.destination_cidr_block == "0.0.0.0/0" &&
    aws_route.workload_default.transit_gateway_id == "tgw-0123456789abcdef0")
    error_message = "The workload subnet must send everything outside the VPC to the transit gateway."
  }

  assert {
    condition     = aws_ec2_transit_gateway_vpc_attachment.this.transit_gateway_id == "tgw-0123456789abcdef0"
    error_message = "The VPC must attach to the given transit gateway."
  }

  assert {
    condition     = aws_vpc.this.tags["Name"] == "svp-lab-net-stg" && aws_subnet.this["tgw"].tags["Name"] == "svp-lab-net-stg-tgw"
    error_message = "Names must follow svp-lab-net-<vpc>[-<tier>], which other roots look up."
  }
}

run "owner_attachment" {
  command = plan

  variables {
    name                            = "svp-lab-net-shared"
    cidr                            = "10.64.16.0/20"
    transit_gateway_in_same_account = true
  }

  assert {
    condition = (aws_ec2_transit_gateway_vpc_attachment.this.transit_gateway_default_route_table_association == false &&
    aws_ec2_transit_gateway_vpc_attachment.this.transit_gateway_default_route_table_propagation == false)
    error_message = "An attachment to a transit gateway of the same account must join no default route table."
  }
}

run "cidr_too_small" {
  command = plan

  variables {
    cidr = "10.64.32.0/24"
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
    transit_gateway_id = "tgw-attach-0123"
  }

  expect_failures = [var.transit_gateway_id]
}

run "name_uppercase" {
  command = plan

  variables {
    name = "Svp-lab-net-stg"
  }

  expect_failures = [var.name]
}
