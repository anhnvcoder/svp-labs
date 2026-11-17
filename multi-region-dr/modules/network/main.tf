# One small VPC per Region: a public subnet for the SSM bastion (public address, no inbound rule, so no NAT gateway) and
# two database subnets with no route out of the VPC. RDS needs a subnet group in two availability zones even for a
# Single-AZ instance. Design notes: multi-region-dr/README.md.

data "aws_availability_zones" "this" {
  state = "available"
}

locals {
  zones = slice(data.aws_availability_zones.this.names, 0, 2)
}

resource "aws_vpc" "this" {
  cidr_block = var.cidr_block

  # A private hosted zone answers inside a VPC only when both are on.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.name
  }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr_block, 4, 0)
  availability_zone = local.zones[0]

  tags = {
    Name = "${var.name}-public"
  }
}

resource "aws_subnet" "db" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr_block, 4, count.index + 1)
  availability_zone = local.zones[count.index]

  tags = {
    Name = "${var.name}-db-${count.index}"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = var.name
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.name}-public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# A table of its own with the local route only, rather than the main table, so that a route added to the main table
# later never reaches the databases. An empty route list also removes any route added outside Terraform.
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.this.id
  route  = []

  tags = {
    Name = "${var.name}-db"
  }
}

resource "aws_route_table_association" "db" {
  count = 2

  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}
