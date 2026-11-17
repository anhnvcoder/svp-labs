# Site-to-Site VPN from the transit gateway to the simulated site: the site's public address, its customer gateway,
# the connection with two tunnels, and the transit gateway routes to and from the site. Static routing: the router is
# a plain IPsec host without a BGP daemon. Design notes: multi-account-networking/README.md.
locals {
  # One set of algorithms for both tunnels and both phases, which the router uses too: IKEv2 only, no legacy cipher.
  tunnel_options = {
    ike_versions        = ["ikev2"]
    encryption          = ["AES256"]
    integrity           = ["SHA2-256"]
    dh_group_numbers    = [14]
    phase1_lifetime_sec = 28800
    phase2_lifetime_sec = 3600
  }
}

# The site's public address: an ISP's in a real site, an Elastic IP here that the router takes over. It exists before
# the customer gateway, which names it, and before the router, whose configuration needs the tunnels.
resource "aws_eip" "this" {
  domain = "vpc"

  tags = {
    Name = "${var.name}-cgw"
  }
}

resource "aws_customer_gateway" "this" {
  type       = "ipsec.1"
  ip_address = aws_eip.this.public_ip

  # Unused with static routing; the API stores this default anyway, and stating it keeps plans clean.
  bgp_asn = "65000"

  tags = {
    Name = var.name
  }
}

resource "aws_vpn_connection" "this" {
  type                = "ipsec.1"
  customer_gateway_id = aws_customer_gateway.this.id
  transit_gateway_id  = var.transit_gateway_id
  static_routes_only  = true

  # AWS generates the keys and keeps them in a Secrets Manager secret of this account; neither Terraform nor its state
  # sees them, and the router reads the secret with its own role.
  preshared_key_storage = "SecretsManager"

  # Traffic selectors: the tunnels carry the site's range to the lab's range and nothing else.
  local_ipv4_network_cidr  = var.site_cidr
  remote_ipv4_network_cidr = var.lab_cidr

  tunnel1_ike_versions                 = local.tunnel_options.ike_versions
  tunnel1_phase1_encryption_algorithms = local.tunnel_options.encryption
  tunnel1_phase1_integrity_algorithms  = local.tunnel_options.integrity
  tunnel1_phase1_dh_group_numbers      = local.tunnel_options.dh_group_numbers
  tunnel1_phase1_lifetime_seconds      = local.tunnel_options.phase1_lifetime_sec
  tunnel1_phase2_encryption_algorithms = local.tunnel_options.encryption
  tunnel1_phase2_integrity_algorithms  = local.tunnel_options.integrity
  tunnel1_phase2_dh_group_numbers      = local.tunnel_options.dh_group_numbers
  tunnel1_phase2_lifetime_seconds      = local.tunnel_options.phase2_lifetime_sec

  tunnel2_ike_versions                 = local.tunnel_options.ike_versions
  tunnel2_phase1_encryption_algorithms = local.tunnel_options.encryption
  tunnel2_phase1_integrity_algorithms  = local.tunnel_options.integrity
  tunnel2_phase1_dh_group_numbers      = local.tunnel_options.dh_group_numbers
  tunnel2_phase1_lifetime_seconds      = local.tunnel_options.phase1_lifetime_sec
  tunnel2_phase2_encryption_algorithms = local.tunnel_options.encryption
  tunnel2_phase2_integrity_algorithms  = local.tunnel_options.integrity
  tunnel2_phase2_dh_group_numbers      = local.tunnel_options.dh_group_numbers
  tunnel2_phase2_lifetime_seconds      = local.tunnel_options.phase2_lifetime_sec

  tags = {
    Name = var.name
  }
}

# The transit gateway has no default table: the VPN attachment looks up the table of the side the site belongs to.
resource "aws_ec2_transit_gateway_route_table_association" "this" {
  transit_gateway_attachment_id  = aws_vpn_connection.this.transit_gateway_attachment_id
  transit_gateway_route_table_id = var.association_route_table_id
}

# A static VPN advertises nothing: each table that may reach the site gets a route to the attachment, each table
# that must not gets a blackhole, more specific than its default route to the egress VPC.
resource "aws_ec2_transit_gateway_route" "this" {
  for_each = merge(
    { for k, id in var.routed_route_table_ids : k => { table = id, blackhole = false } },
    { for k, id in var.blackholed_route_table_ids : k => { table = id, blackhole = true } },
  )

  transit_gateway_route_table_id = each.value.table
  destination_cidr_block         = var.site_cidr
  transit_gateway_attachment_id  = each.value.blackhole ? null : aws_vpn_connection.this.transit_gateway_attachment_id
  blackhole                      = each.value.blackhole
}
