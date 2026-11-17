# The VPN of the lab with its ranges and route tables: one assertion per decision, then one plan per validation rule.
# The AWS provider is a mock: nothing reaches an account. The attachment ID exists only after apply, so routes are
# checked by table and kind.

mock_provider "aws" {}

variables {
  name                       = "svp-lab-net-vpn"
  transit_gateway_id         = "tgw-0123456789abcdef0"
  site_cidr                  = "192.168.0.0/20"
  lab_cidr                   = "10.64.0.0/16"
  association_route_table_id = "tgw-rtb-0bbbbbbbbbbbbbbb2"
  routed_route_table_ids     = { nonprd = "tgw-rtb-0bbbbbbbbbbbbbbb2" }
  blackholed_route_table_ids = { prd = "tgw-rtb-0aaaaaaaaaaaaaaa1" }
}

run "vpn" {
  command = plan

  assert {
    condition     = aws_vpn_connection.this.preshared_key_storage == "SecretsManager"
    error_message = "The keys must live in Secrets Manager, out of Terraform and its state."
  }

  assert {
    condition = (aws_vpn_connection.this.static_routes_only == true &&
    aws_vpn_connection.this.transit_gateway_id == "tgw-0123456789abcdef0" && aws_vpn_connection.this.vpn_gateway_id == null)
    error_message = "One static VPN, attached straight to the transit gateway."
  }

  assert {
    condition = (aws_vpn_connection.this.local_ipv4_network_cidr == "192.168.0.0/20" &&
    aws_vpn_connection.this.remote_ipv4_network_cidr == "10.64.0.0/16")
    error_message = "The tunnels must carry the site's range to the lab's range only."
  }

  assert {
    condition = alltrue([for v in [aws_vpn_connection.this.tunnel1_ike_versions, aws_vpn_connection.this.tunnel2_ike_versions] :
    v == toset(["ikev2"])])
    error_message = "Both tunnels must refuse IKEv1."
  }

  assert {
    condition = alltrue([for v in [
      aws_vpn_connection.this.tunnel1_phase1_encryption_algorithms, aws_vpn_connection.this.tunnel1_phase2_encryption_algorithms,
      aws_vpn_connection.this.tunnel2_phase1_encryption_algorithms, aws_vpn_connection.this.tunnel2_phase2_encryption_algorithms,
    ] : v == toset(["AES256"])])
    error_message = "Both phases of both tunnels must use AES256 only."
  }

  assert {
    condition = alltrue([for v in [
      aws_vpn_connection.this.tunnel1_phase1_dh_group_numbers, aws_vpn_connection.this.tunnel1_phase2_dh_group_numbers,
      aws_vpn_connection.this.tunnel2_phase1_dh_group_numbers, aws_vpn_connection.this.tunnel2_phase2_dh_group_numbers,
    ] : v == toset([14])])
    error_message = "Both phases of both tunnels must use DH group 14 only, as the router does."
  }

  assert {
    condition     = aws_ec2_transit_gateway_route_table_association.this.transit_gateway_route_table_id == "tgw-rtb-0bbbbbbbbbbbbbbb2"
    error_message = "The VPN attachment must look up the non-prd table."
  }

  assert {
    condition = (aws_ec2_transit_gateway_route.this["nonprd"].blackhole == false &&
      aws_ec2_transit_gateway_route.this["nonprd"].transit_gateway_route_table_id == "tgw-rtb-0bbbbbbbbbbbbbbb2" &&
    aws_ec2_transit_gateway_route.this["nonprd"].destination_cidr_block == "192.168.0.0/20")
    error_message = "The non-prd table must route the site's range to the VPN."
  }

  assert {
    condition = (aws_ec2_transit_gateway_route.this["prd"].blackhole == true &&
      aws_ec2_transit_gateway_route.this["prd"].transit_gateway_attachment_id == null &&
    aws_ec2_transit_gateway_route.this["prd"].transit_gateway_route_table_id == "tgw-rtb-0aaaaaaaaaaaaaaa1")
    error_message = "The prd table must blackhole the site's range."
  }

  assert {
    condition     = length(aws_ec2_transit_gateway_route.this) == 2
    error_message = "Expected exactly two routes: one to the site, one blackhole."
  }

  assert {
    condition     = aws_eip.this.domain == "vpc" && aws_customer_gateway.this.type == "ipsec.1"
    error_message = "The customer gateway must be an IPsec gateway on an Elastic IP."
  }
}

run "table_both_ways" {
  command = plan

  variables {
    blackholed_route_table_ids = { nonprd = "tgw-rtb-0bbbbbbbbbbbbbbb2" }
  }

  expect_failures = [var.blackholed_route_table_ids]
}

run "no_routed_table" {
  command = plan

  variables {
    routed_route_table_ids = {}
  }

  expect_failures = [var.routed_route_table_ids]
}

run "site_everything" {
  command = plan

  variables {
    site_cidr = "0.0.0.0/0"
  }

  expect_failures = [var.site_cidr]
}

run "association_not_table" {
  command = plan

  variables {
    association_route_table_id = "tgw-0123456789abcdef0"
  }

  expect_failures = [var.association_route_table_id]
}

run "name_uppercase" {
  command = plan

  variables {
    name = "Svp-lab-net-vpn"
  }

  expect_failures = [var.name]
}
