locals {
  # One zone and the lab's only NAT gateway. public holds the NAT gateway, tgw the attachment, probe the test
  # instance; the attachment has a /28 of its own, as the transit gateway design guide recommends.
  subnets = {
    public = cidrsubnet(var.cidr, 4, 0)
    tgw    = cidrsubnet(var.cidr, 8, 16)
    probe  = cidrsubnet(var.cidr, 4, 2)
  }

  # Next hop by subnet and destination. Spoke traffic enters on the tgw subnet and goes to the NAT gateway; replies of
  # the NAT gateway and the probe's own traffic to the spokes go back to the transit gateway.
  routes = {
    "public|0.0.0.0/0"          = "igw"
    "public|${var.spokes_cidr}" = "tgw"
    "tgw|0.0.0.0/0"             = "nat"
    "probe|0.0.0.0/0"           = "nat"
    "probe|${var.spokes_cidr}"  = "tgw"
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.name
  }
}

# Emptied of rules: a resource left on the default group gets no traffic in or out.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name}-default"
  }
}

resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id               = aws_vpc.this.id
  cidr_block           = each.value
  availability_zone_id = var.availability_zone_id

  # No address of its own on launch: only the NAT gateway has a public one, given explicitly.
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name}-${each.key}"
  }
}

resource "aws_route_table" "this" {
  for_each = local.subnets

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name}-${each.key}"
  }
}

resource "aws_route_table_association" "this" {
  for_each = local.subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.this[each.key].id
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = var.name
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.name}-nat"
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id     = aws_eip.nat.id
  subnet_id         = aws_subnet.this["public"].id
  connectivity_type = "public"

  tags = {
    Name = var.name
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = var.transit_gateway_id
  vpc_id             = aws_vpc.this.id
  subnet_ids         = [aws_subnet.this["tgw"].id]

  # Same account as the transit gateway, which has no default table.
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = {
    Name = var.name
  }
}

resource "aws_route" "this" {
  for_each = local.routes

  route_table_id         = aws_route_table.this[split("|", each.key)[0]].id
  destination_cidr_block = split("|", each.key)[1]
  gateway_id             = each.value == "igw" ? aws_internet_gateway.this.id : null
  nat_gateway_id         = each.value == "nat" ? aws_nat_gateway.this.id : null
  transit_gateway_id     = each.value == "tgw" ? var.transit_gateway_id : null

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}
