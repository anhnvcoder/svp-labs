# Validation rules of the variables, then the link the lab relies on: a peering accepted in the same account and each
# side routing only the other side's range through it. The AWS provider is a mock.

mock_provider "aws" {}

variables {
  name = "svp-lab-dms-peering"
  requester = {
    vpc_id         = "vpc-0aaaaaaaaaaaaaaa1"
    cidr           = "192.168.16.0/20"
    route_table_id = "rtb-0aaaaaaaaaaaaaaa1"
  }
  accepter = {
    vpc_id         = "vpc-0bbbbbbbbbbbbbbb2"
    cidr           = "10.66.0.0/20"
    route_table_id = "rtb-0bbbbbbbbbbbbbbb2"
  }
}

run "link" {
  command = plan

  assert {
    condition     = aws_vpc_peering_connection.this.auto_accept && aws_vpc_peering_connection.this.vpc_id == "vpc-0aaaaaaaaaaaaaaa1" && aws_vpc_peering_connection.this.peer_vpc_id == "vpc-0bbbbbbbbbbbbbbb2"
    error_message = "The on-premises stand-in requests the peering and the same account accepts it at once."
  }

  assert {
    condition     = aws_route.requester.route_table_id == "rtb-0aaaaaaaaaaaaaaa1" && aws_route.requester.destination_cidr_block == "10.66.0.0/20"
    error_message = "The on-premises side routes the AWS range only."
  }

  assert {
    condition     = aws_route.accepter.route_table_id == "rtb-0bbbbbbbbbbbbbbb2" && aws_route.accepter.destination_cidr_block == "192.168.16.0/20"
    error_message = "The AWS side routes the on-premises range only."
  }
}

run "same_vpc_twice" {
  command = plan

  variables {
    accepter = {
      vpc_id         = "vpc-0aaaaaaaaaaaaaaa1"
      cidr           = "192.168.16.0/20"
      route_table_id = "rtb-0aaaaaaaaaaaaaaa1"
    }
  }

  expect_failures = [var.accepter]
}

run "requester_without_route_table" {
  command = plan

  variables {
    requester = {
      vpc_id         = "vpc-0aaaaaaaaaaaaaaa1"
      cidr           = "192.168.16.0/20"
      route_table_id = "subnet-0aaaaaaaaaaaaaaa1"
    }
  }

  expect_failures = [var.requester]
}

run "name_outside_the_lab" {
  command = plan

  variables {
    name = "svp-prd-peering"
  }

  expect_failures = [var.name]
}
