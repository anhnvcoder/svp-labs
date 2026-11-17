# The core of the lab: a transit gateway in svp-network joins the VPCs of network, stg and prd, with prd and non-prd
# apart and a single internet exit; a subnet and the central DNS are shared through RAM.
# Design notes: multi-account-networking/README.md.
locals {
  # Every VPC of the lab sits in this range; on-premises networks use other ranges.
  lab_cidr = "10.64.0.0/16"

  cidrs = {
    egress = "10.64.0.0/20"
    shared = "10.64.16.0/20"
    stg    = "10.64.32.0/20"
    prd    = "10.64.48.0/20"
  }
}

# Sharing within the organization is a switch of the management account; the session turns it on and its destroy
# turns it off again. Every share below waits for it, so a destroy removes them before the switch goes off.
resource "aws_ram_sharing_with_organization" "this" {
  provider = aws.management
}

module "hub" {
  source = "../modules/tgw-hub"

  providers = {
    aws = aws.network
  }

  name = "svp-lab-net"
  attachments = {
    egress = { id = module.egress.attachment_id, cidr = local.cidrs.egress }
    shared = { id = module.shared_vpc.attachment_id, cidr = local.cidrs.shared }
    stg    = { id = module.stg_vpc.attachment_id, cidr = local.cidrs.stg }
    prd    = { id = module.prd_vpc.attachment_id, cidr = local.cidrs.prd }
  }
}

module "tgw_share" {
  source = "../modules/ram-share"

  providers = {
    aws = aws.network
  }

  name          = "svp-lab-net-tgw"
  resource_arns = { tgw = module.hub.transit_gateway_arn }
  principals    = [var.stg_account_id, var.prd_account_id]

  depends_on = [aws_ram_sharing_with_organization.this]
}

module "egress" {
  source = "../modules/egress-vpc"

  providers = {
    aws = aws.network
  }

  name                 = "svp-lab-net-egress"
  cidr                 = local.cidrs.egress
  spokes_cidr          = local.lab_cidr
  availability_zone_id = var.availability_zone_id
  transit_gateway_id   = module.hub.transit_gateway_id
}

# The shared VPC belongs to svp-network; its workload subnet is shared with stg, which runs its own instance there.
module "shared_vpc" {
  source = "../modules/spoke-vpc"

  providers = {
    aws = aws.network
  }

  name                            = "svp-lab-net-shared"
  cidr                            = local.cidrs.shared
  availability_zone_id            = var.availability_zone_id
  transit_gateway_id              = module.hub.transit_gateway_id
  transit_gateway_in_same_account = true
}

module "subnet_share" {
  source = "../modules/ram-share"

  providers = {
    aws = aws.network
  }

  name          = "svp-lab-net-subnet"
  resource_arns = { workload = module.shared_vpc.workload_subnet_arn }
  principals    = [var.stg_account_id]

  depends_on = [aws_ram_sharing_with_organization.this]
}

# A spoke account attaches to the transit gateway only once the share has reached it.
module "stg_vpc" {
  source = "../modules/spoke-vpc"

  providers = {
    aws = aws.stg
  }

  name                            = "svp-lab-net-stg"
  cidr                            = local.cidrs.stg
  availability_zone_id            = var.availability_zone_id
  transit_gateway_id              = module.hub.transit_gateway_id
  transit_gateway_in_same_account = false

  depends_on = [module.tgw_share]
}

module "prd_vpc" {
  source = "../modules/spoke-vpc"

  providers = {
    aws = aws.prd
  }

  name                            = "svp-lab-net-prd"
  cidr                            = local.cidrs.prd
  availability_zone_id            = var.availability_zone_id
  transit_gateway_id              = module.hub.transit_gateway_id
  transit_gateway_in_same_account = false

  depends_on = [module.tgw_share]
}

module "probe_egress" {
  source = "../modules/probe"

  providers = {
    aws = aws.network
  }

  name      = "svp-lab-net-probe-egress"
  vpc_id    = module.egress.vpc_id
  subnet_id = module.egress.probe_subnet_id
  lab_cidr  = local.lab_cidr
}

# The instance of stg in the subnet that svp-network shares: stg owns the instance and its security group, svp-network
# keeps the VPC, its route tables and its network ACLs.
module "probe_shared" {
  source = "../modules/probe"

  providers = {
    aws = aws.stg
  }

  name      = "svp-lab-net-probe-shared"
  vpc_id    = module.shared_vpc.vpc_id
  subnet_id = module.shared_vpc.workload_subnet_id
  lab_cidr  = local.lab_cidr

  depends_on = [module.subnet_share]
}

module "probe_stg" {
  source = "../modules/probe"

  providers = {
    aws = aws.stg
  }

  name      = "svp-lab-net-probe-stg"
  vpc_id    = module.stg_vpc.vpc_id
  subnet_id = module.stg_vpc.workload_subnet_id
  lab_cidr  = local.lab_cidr
}

module "probe_prd" {
  source = "../modules/probe"

  providers = {
    aws = aws.prd
  }

  name      = "svp-lab-net-probe-prd"
  vpc_id    = module.prd_vpc.vpc_id
  subnet_id = module.prd_vpc.workload_subnet_id
  lab_cidr  = local.lab_cidr
}

module "dns_hub" {
  source = "../modules/dns-hub"

  providers = {
    aws = aws.network
  }

  name   = "svp-lab-net"
  vpc_id = module.shared_vpc.vpc_id
  records = {
    net = {
      egress-probe = module.probe_egress.private_ip
      shared-probe = module.probe_shared.private_ip
    }
    nonprd = {
      shared-probe = module.probe_shared.private_ip
    }
  }
  nonprd_vpc_ids = { stg = module.stg_vpc.vpc_id }
}

module "dns_share" {
  source = "../modules/ram-share"

  providers = {
    aws = aws.network
  }

  name          = "svp-lab-net-dns"
  resource_arns = { profile = module.dns_hub.profile_arn }
  principals    = [var.stg_account_id, var.prd_account_id]

  depends_on = [aws_ram_sharing_with_organization.this]
}

# stg gets the zone net through the Profile and the zone nonprd through the zone owner's authorization; prd gets the
# Profile only, so nonprd.svp.example does not resolve there.
module "dns_stg" {
  source = "../modules/dns-spoke"

  providers = {
    aws = aws.stg
  }

  name       = "svp-lab-net-stg"
  vpc_id     = module.stg_vpc.vpc_id
  profile_id = module.dns_hub.profile_id
  zone_ids   = { nonprd = module.dns_hub.zone_ids["nonprd"] }

  depends_on = [module.dns_share, module.dns_hub]
}

module "dns_prd" {
  source = "../modules/dns-spoke"

  providers = {
    aws = aws.prd
  }

  name       = "svp-lab-net-prd"
  vpc_id     = module.prd_vpc.vpc_id
  profile_id = module.dns_hub.profile_id

  depends_on = [module.dns_share]
}
