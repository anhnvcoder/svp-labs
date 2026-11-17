locals {
  # One zone, a /24 for the workload and a /28 of its own for the transit gateway attachment, as the transit gateway
  # design guide recommends: the lab measures paths between accounts, not the loss of a zone.
  subnets = {
    workload = cidrsubnet(var.cidr, 4, 0)
    tgw      = cidrsubnet(var.cidr, 8, 16)
  }
}

resource "aws_vpc" "this" {
  cidr_block = var.cidr

  # A private hosted zone answers only VPCs with both DNS attributes on.
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

  # No public address on launch: a spoke reaches the internet only through the central egress.
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

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = var.transit_gateway_id
  vpc_id             = aws_vpc.this.id
  subnet_ids         = [aws_subnet.this["tgw"].id]

  # The provider manages the default table only for a transit gateway of the VPC's own account and must leave these
  # unset for one shared through RAM; the hub has no default table, so the owner's attachments say so.
  transit_gateway_default_route_table_association = var.transit_gateway_in_same_account ? false : null
  transit_gateway_default_route_table_propagation = var.transit_gateway_in_same_account ? false : null

  tags = {
    Name = var.name
  }
}

# Everything outside the VPC goes to the transit gateway, whose route tables decide where it may go. The tgw subnet
# keeps the local route only. The route waits for the attachment: before it the transit gateway is no target here.
resource "aws_route" "workload_default" {
  route_table_id         = aws_route_table.this["workload"].id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}
