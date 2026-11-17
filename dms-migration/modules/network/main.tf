# One VPC of the lab: "public" holds the on-premises stand-in (one subnet routed to an internet gateway, for the SSM
# agent and the package repositories); "private" holds RDS and DMS (two subnets, the two zones RDS and DMS subnet groups
# require, no route out). Routes live in aws_route resources so the peering module can add its own.
# Design notes: dms-migration/README.md.

data "aws_availability_zones" "this" {
  state = "available"
}

locals {
  public = var.subnets == "public"
  count  = local.public ? 1 : 2
  zones  = slice(data.aws_availability_zones.this.names, 0, local.count)
}

resource "aws_vpc" "this" {
  cidr_block = var.cidr_block

  # The private DNS name of an interface endpoint resolves only when both are on.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.name
  }
}

resource "aws_subnet" "this" {
  count = local.count

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr_block, 4, count.index)
  availability_zone = local.zones[count.index]

  tags = {
    Name = "${var.name}-${var.subnets}-${count.index}"
  }
}

resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name}-${var.subnets}"
  }
}

resource "aws_route_table_association" "this" {
  count = local.count

  subnet_id      = aws_subnet.this[count.index].id
  route_table_id = aws_route_table.this.id
}

resource "aws_internet_gateway" "this" {
  count = local.public ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = {
    Name = var.name
  }
}

resource "aws_route" "internet" {
  count = local.public ? 1 : 0

  route_table_id         = aws_route_table.this.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}
