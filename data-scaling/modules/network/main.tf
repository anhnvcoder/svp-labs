# The VPC of one part of the lab: a public subnet for the SSM loader (public address, no inbound rule, so no NAT
# gateway) and two data subnets with no route out of the VPC, in two zones because DB and ElastiCache subnet groups
# require two. Design notes: data-scaling/README.md.

data "aws_availability_zones" "this" {
  state = "available"
}

locals {
  # Sorted, so that the zones do not move when the API lists them in another order.
  zones = slice(sort(data.aws_availability_zones.this.names), 0, 2)
}

resource "aws_vpc" "this" {
  cidr_block = var.cidr_block

  # Endpoint names of RDS, RDS Proxy and ElastiCache resolve to private addresses only when both are on.
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

resource "aws_subnet" "data" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr_block, 4, count.index + 1)
  availability_zone = local.zones[count.index]

  tags = {
    Name = "${var.name}-data-${count.index}"
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
# later never reaches the data subnets. An empty route list also removes any route added outside Terraform.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id
  route  = []

  tags = {
    Name = "${var.name}-data"
  }
}

resource "aws_route_table_association" "data" {
  count = 2

  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}
