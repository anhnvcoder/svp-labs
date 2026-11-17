variable "name" {
  description = "Prefix of the endpoints, their security groups and the rule (<name>-inbound, <name>-outbound, <name>-site), e.g. svp-lab-net-resolver."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 32 lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "vpc_id" {
  description = "ID of the VPC of both endpoints, one whose private zones the site asks for (the lab's shared VPC)."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC ID, e.g. vpc-0123456789abcdef0."
  }
}

variable "availability_zone_id" {
  description = "Zone of the endpoints' subnet, by zone ID: the zone of the VPC's transit gateway attachment, e.g. apse1-az1."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+[0-9]-az[0-9]+$", var.availability_zone_id))
    error_message = "availability_zone_id must be a zone ID such as apse1-az1."
  }
}

variable "subnet_cidr" {
  description = "A free /28 of the VPC for the endpoints' own subnet, e.g. 10.64.18.0/28: inbound takes its .4 and .5, outbound .6 and .7."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.subnet_cidr)) && endswith(var.subnet_cidr, "/28")
    error_message = "subnet_cidr must be an IPv4 /28, e.g. 10.64.18.0/28."
  }
}

variable "transit_gateway_id" {
  description = "ID of the transit gateway the VPC is attached to, the next hop to the site."
  type        = string

  validation {
    condition     = can(regex("^tgw-[0-9a-f]+$", var.transit_gateway_id))
    error_message = "transit_gateway_id must be a transit gateway ID, e.g. tgw-0123456789abcdef0."
  }
}

variable "site_cidr" {
  description = "IPv4 range of the simulated site, the only source of queries to the inbound endpoint, e.g. 192.168.0.0/20."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.site_cidr)) && var.site_cidr != "0.0.0.0/0"
    error_message = "site_cidr must be an IPv4 range other than 0.0.0.0/0, e.g. 192.168.0.0/20."
  }
}

variable "site_dns_ip" {
  description = "Address of the site's DNS server, the only target of the outbound endpoint, e.g. 192.168.0.10."
  type        = string

  validation {
    condition     = can(cidrhost("${var.site_dns_ip}/32", 0))
    error_message = "site_dns_ip must be an IPv4 address."
  }
}

variable "site_zone" {
  description = "Zone the site's server holds, which the rule forwards to it, e.g. onprem.svp.example."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9-]+\\.)+[a-z]+$", var.site_zone))
    error_message = "site_zone must be a domain name in lowercase, e.g. onprem.svp.example."
  }
}

variable "profile_id" {
  description = "ID of the Route 53 Profile of this account that the spoke VPCs are associated with."
  type        = string

  validation {
    condition     = can(regex("^rp-[0-9a-z]+$", var.profile_id))
    error_message = "profile_id must be a Route 53 Profile ID, e.g. rp-0123456789abcdef."
  }
}
