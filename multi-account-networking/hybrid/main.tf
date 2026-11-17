# The hybrid part of the lab, on top of the root core: a simulated on-premises site joined to the transit gateway by
# Site-to-Site VPN, Resolver endpoints for DNS both ways, and PrivateLink from prd to stg. It finds what core built by
# name and tag, never through core's state. Design notes: multi-account-networking/README.md.
locals {
  lab_cidr  = "10.64.0.0/16"
  site_cidr = "192.168.0.0/20"
  site_zone = "onprem.svp.example"

  # A free /28 of the shared VPC (10.64.16.0/20), after the workload /24 and the attachment /28 of core.
  resolver_subnet_cidr = "10.64.18.0/28"

  # Private zones of core that the site asks for through the inbound endpoint.
  lab_zones = ["net.svp.example", "nonprd.svp.example"]
}

data "aws_ec2_transit_gateway" "hub" {
  provider = aws.network

  filter {
    name   = "tag:Name"
    values = ["svp-lab-net"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

data "aws_ec2_transit_gateway_route_table" "this" {
  for_each = toset(["prd", "nonprd"])
  provider = aws.network

  filter {
    name   = "tag:Name"
    values = ["svp-lab-net-rt-${each.key}"]
  }

  filter {
    name   = "transit-gateway-id"
    values = [data.aws_ec2_transit_gateway.hub.id]
  }
}

data "aws_vpc" "shared" {
  provider = aws.network

  filter {
    name   = "tag:Name"
    values = ["svp-lab-net-shared"]
  }
}

data "aws_route53profiles_profiles" "network" {
  provider = aws.network
}

data "aws_vpc" "stg" {
  provider = aws.stg

  filter {
    name   = "tag:Name"
    values = ["svp-lab-net-stg"]
  }
}

data "aws_vpc" "prd" {
  provider = aws.prd

  filter {
    name   = "tag:Name"
    values = ["svp-lab-net-prd"]
  }
}

data "aws_subnet" "stg_workload" {
  provider = aws.stg

  filter {
    name   = "tag:Name"
    values = ["svp-lab-net-stg-workload"]
  }
}

data "aws_subnet" "prd_workload" {
  provider = aws.prd

  filter {
    name   = "tag:Name"
    values = ["svp-lab-net-prd-workload"]
  }
}

data "aws_security_group" "probe_stg" {
  provider = aws.stg

  filter {
    name   = "group-name"
    values = ["svp-lab-net-probe-stg"]
  }

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.stg.id]
  }
}

data "aws_instance" "probe_prd" {
  provider = aws.prd

  filter {
    name   = "tag:Name"
    values = ["svp-lab-net-probe-prd"]
  }

  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

# The VPN attachment joins the non-prd side: stg and the shared VPC reach the site, prd gets a blackhole. Routing prd
# to the site too would let the site carry packets between prd and stg; that needs a table of its own for the VPN
# and a firewall at the site, which the lab does not build.
module "vpn" {
  source = "../modules/site-vpn"

  providers = {
    aws = aws.network
  }

  name                       = "svp-lab-net-vpn"
  transit_gateway_id         = data.aws_ec2_transit_gateway.hub.id
  site_cidr                  = local.site_cidr
  lab_cidr                   = local.lab_cidr
  association_route_table_id = data.aws_ec2_transit_gateway_route_table.this["nonprd"].id
  routed_route_table_ids     = { nonprd = data.aws_ec2_transit_gateway_route_table.this["nonprd"].id }
  blackholed_route_table_ids = { prd = data.aws_ec2_transit_gateway_route_table.this["prd"].id }
}

module "resolver" {
  source = "../modules/dns-resolver"

  providers = {
    aws = aws.network
  }

  name                 = "svp-lab-net-resolver"
  vpc_id               = data.aws_vpc.shared.id
  availability_zone_id = var.availability_zone_id
  subnet_cidr          = local.resolver_subnet_cidr
  transit_gateway_id   = data.aws_ec2_transit_gateway.hub.id
  site_cidr            = local.site_cidr
  site_dns_ip          = module.site.router_private_ip
  site_zone            = local.site_zone
  profile_id           = one([for p in data.aws_route53profiles_profiles.network.profiles : p.id if p.name == "svp-lab-net"])
}

module "site" {
  source = "../modules/onprem-site"

  providers = {
    aws = aws.network
  }

  name                 = "svp-lab-net-onprem"
  cidr                 = local.site_cidr
  lab_cidr             = local.lab_cidr
  availability_zone_id = var.availability_zone_id
  public_ip            = module.vpn.public_ip
  eip_allocation_id    = module.vpn.eip_allocation_id
  tunnels              = module.vpn.tunnels
  preshared_key_arn    = module.vpn.preshared_key_arn
  zone_name            = local.site_zone
  forward_zones        = local.lab_zones
  inbound_resolver_ips = module.resolver.inbound_ips
}

# The probe of stg admits the lab's range only; these rules, removed with this root, let it talk to the site.
resource "aws_vpc_security_group_ingress_rule" "probe_stg_site" {
  for_each = {
    icmp = { ip_protocol = "icmp", from_port = -1, to_port = -1 }
    http = { ip_protocol = "tcp", from_port = 80, to_port = 80 }
  }
  provider = aws.stg

  security_group_id = data.aws_security_group.probe_stg.id
  description       = "${each.key} from the simulated site"
  ip_protocol       = each.value.ip_protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  cidr_ipv4         = local.site_cidr
}

resource "aws_vpc_security_group_egress_rule" "probe_stg_site" {
  provider = aws.stg

  security_group_id = data.aws_security_group.probe_stg.id
  description       = "Any traffic to the simulated site"
  ip_protocol       = "-1"
  cidr_ipv4         = local.site_cidr
}

# PrivateLink from prd to stg: the probe of prd serves HTTP behind an endpoint service, and stg reaches it through an
# interface endpoint in its own VPC, while the transit gateway still drops every packet between the two.
module "service_prd" {
  source = "../modules/privatelink-provider"

  providers = {
    aws = aws.prd
  }

  name                  = "svp-lab-net-svc"
  vpc_id                = data.aws_vpc.prd.id
  subnet_id             = data.aws_subnet.prd_workload.id
  instance_id           = data.aws_instance.probe_prd.id
  consumer_account_id   = var.stg_account_id
  accepted_endpoint_ids = { stg = module.service_stg.endpoint_id }
}

module "service_stg" {
  source = "../modules/privatelink-consumer"

  providers = {
    aws = aws.stg
  }

  name         = "svp-lab-net-svc-stg"
  vpc_id       = data.aws_vpc.stg.id
  vpc_cidr     = data.aws_vpc.stg.cidr_block
  subnet_id    = data.aws_subnet.stg_workload.id
  service_name = module.service_prd.service_name
}
