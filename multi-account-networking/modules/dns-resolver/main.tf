# Hybrid DNS of the network account: an inbound endpoint where the site's DNS server asks for the lab's private zones,
# an outbound endpoint and a forwarding rule that send the site's zone to that server, and the rule added to the
# Route 53 Profile that the spoke accounts already share. Design notes: multi-account-networking/README.md.
locals {
  # Two fixed addresses per endpoint, the minimum Resolver accepts, in a subnet of their own in the lab's one zone:
  # the plan knows them, and no other instance can take them first. AWS reserves .0 to .3 of every subnet.
  addresses = {
    inbound  = [cidrhost(var.subnet_cidr, 4), cidrhost(var.subnet_cidr, 5)]
    outbound = [cidrhost(var.subnet_cidr, 6), cidrhost(var.subnet_cidr, 7)]
  }
  protocols = toset(["udp", "tcp"])
}

resource "aws_subnet" "this" {
  vpc_id               = var.vpc_id
  cidr_block           = var.subnet_cidr
  availability_zone_id = var.availability_zone_id

  tags = {
    Name = var.name
  }
}

resource "aws_route_table" "this" {
  vpc_id = var.vpc_id

  tags = {
    Name = var.name
  }
}

resource "aws_route_table_association" "this" {
  subnet_id      = aws_subnet.this.id
  route_table_id = aws_route_table.this.id
}

# The endpoints talk to the site alone; the VPC's other subnets keep their own routes.
resource "aws_route" "site" {
  route_table_id         = aws_route_table.this.id
  destination_cidr_block = var.site_cidr
  transit_gateway_id     = var.transit_gateway_id
}

resource "aws_security_group" "inbound" {
  name        = "${var.name}-inbound"
  description = "Inbound Resolver endpoint: DNS from the simulated site"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-inbound"
  }
}

resource "aws_vpc_security_group_ingress_rule" "inbound" {
  for_each = local.protocols

  security_group_id = aws_security_group.inbound.id
  description       = "DNS over ${each.key} from the site"
  ip_protocol       = each.key
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = var.site_cidr
}

# No ingress rule: the endpoint only sends queries, and the answers return on the tracked connection.
resource "aws_security_group" "outbound" {
  name        = "${var.name}-outbound"
  description = "Outbound Resolver endpoint: DNS to the site's server only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-outbound"
  }
}

resource "aws_vpc_security_group_egress_rule" "outbound" {
  for_each = local.protocols

  security_group_id = aws_security_group.outbound.id
  description       = "DNS over ${each.key} to the site's server"
  ip_protocol       = each.key
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "${var.site_dns_ip}/32"
}

resource "aws_route53_resolver_endpoint" "this" {
  for_each = {
    inbound  = { direction = "INBOUND", security_group_id = aws_security_group.inbound.id }
    outbound = { direction = "OUTBOUND", security_group_id = aws_security_group.outbound.id }
  }

  name               = "${var.name}-${each.key}"
  direction          = each.value.direction
  security_group_ids = [each.value.security_group_id]

  dynamic "ip_address" {
    for_each = local.addresses[each.key]

    content {
      subnet_id = aws_subnet.this.id
      ip        = ip_address.value
    }
  }

  tags = {
    Name = "${var.name}-${each.key}"
  }
}

resource "aws_route53_resolver_rule" "site" {
  name                 = "${var.name}-site"
  domain_name          = var.site_zone
  rule_type            = "FORWARD"
  resolver_endpoint_id = aws_route53_resolver_endpoint.this["outbound"].id

  target_ip {
    ip   = var.site_dns_ip
    port = 53
  }

  tags = {
    Name = "${var.name}-site"
  }
}

# The Profile reaches every VPC associated with it, in every account it is shared with; the rule rides on that share
# and needs none of its own.
resource "aws_route53profiles_resource_association" "site" {
  name         = "${var.name}-site"
  profile_id   = var.profile_id
  resource_arn = aws_route53_resolver_rule.site.arn
}
