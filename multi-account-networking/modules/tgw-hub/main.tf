# Every attachment joins exactly one route table and nothing propagates: each route below is static, so a plan shows
# the whole routing of the hub. Design notes: multi-account-networking/README.md.
locals {
  # The shared VPC holds the subnet shared with stg only, so it sits on the non-prd side.
  route_table_of = {
    egress = "egress"
    shared = "nonprd"
    stg    = "nonprd"
    prd    = "prd"
  }

  # Each env table and the table of the other env.
  other_env = {
    prd    = "nonprd"
    nonprd = "prd"
  }

  default_routes = {
    for t in keys(local.other_env) : "${t}|0.0.0.0/0" => { table = t, cidr = "0.0.0.0/0", attachment = "egress" }
  }

  # Without the blackholes a packet from one env to the other would follow the default route into the egress VPC, and
  # the NAT gateway would send it back through the transit gateway to the other env. A blackhole of the other env's
  # CIDR is more specific than 0.0.0.0/0, so the transit gateway drops that packet first.
  env_routes = merge([
    for t, other in local.other_env : {
      for k, a in var.attachments : "${t}|${a.cidr}" => {
        table      = t
        cidr       = a.cidr
        attachment = local.route_table_of[k] == t ? k : null
      } if contains([t, other], local.route_table_of[k])
    }
  ]...)

  # Replies from the internet leave the NAT gateway for a spoke address: the egress table carries them back.
  return_routes = {
    for k, a in var.attachments : "egress|${a.cidr}" => { table = "egress", cidr = a.cidr, attachment = k } if k != "egress"
  }

  routes = merge(local.default_routes, local.env_routes, local.return_routes)
}

resource "aws_ec2_transit_gateway" "this" {
  description = "Hub of the multi-account networking lab"

  # The spokes attach from other accounts of the organization, which alone can see the RAM share; accepting each
  # attachment by hand would add a step to every session and no control.
  auto_accept_shared_attachments = "enable"

  # No default table: an attachment that landed in one would reach every VPC that propagated into it.
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  dns_support                     = "enable"

  tags = {
    Name = var.name
  }
}

resource "aws_ec2_transit_gateway_route_table" "this" {
  for_each = toset(["prd", "nonprd", "egress"])

  transit_gateway_id = aws_ec2_transit_gateway.this.id

  tags = {
    Name = "${var.name}-rt-${each.key}"
  }
}

resource "aws_ec2_transit_gateway_route_table_association" "this" {
  for_each = var.attachments

  transit_gateway_attachment_id  = each.value.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this[local.route_table_of[each.key]].id
}

resource "aws_ec2_transit_gateway_route" "this" {
  for_each = local.routes

  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this[each.value.table].id
  destination_cidr_block         = each.value.cidr
  transit_gateway_attachment_id  = each.value.attachment == null ? null : var.attachments[each.value.attachment].id
  blackhole                      = each.value.attachment == null
}
