variable "name" {
  description = "Name of the VPC and prefix of the names of its subnets and route tables (<name>-public, <name>-tgw, <name>-probe), e.g. svp-lab-net-egress."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 32 lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "cidr" {
  description = "IPv4 range of the VPC, a /16 to /20: public is its first sixteenth, probe its third sixteenth, and the attachment subnet a 256th of it (a /28 in a /20) right after public."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.cidr)) && tonumber(split("/", var.cidr)[1]) >= 16 && tonumber(split("/", var.cidr)[1]) <= 20
    error_message = "cidr must be an IPv4 range from /16 to /20, e.g. 10.64.0.0/20."
  }
}

variable "spokes_cidr" {
  description = "IPv4 range that covers every VPC behind the transit gateway, e.g. 10.64.0.0/16: replies of the NAT gateway and the probe's traffic to that range go back through the transit gateway."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.spokes_cidr)) && var.spokes_cidr != "0.0.0.0/0"
    error_message = "spokes_cidr must be an IPv4 range other than 0.0.0.0/0, e.g. 10.64.0.0/16."
  }
}

variable "availability_zone_id" {
  description = "Zone of every subnet, by zone ID (e.g. apse1-az1), the same as the spokes so that no packet crosses zones."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+[0-9]-az[0-9]+$", var.availability_zone_id))
    error_message = "availability_zone_id must be a zone ID such as apse1-az1."
  }
}

variable "transit_gateway_id" {
  description = "ID of the transit gateway of the same account the VPC attaches to."
  type        = string

  validation {
    condition     = can(regex("^tgw-[0-9a-f]+$", var.transit_gateway_id))
    error_message = "transit_gateway_id must be a transit gateway ID, e.g. tgw-0123456789abcdef0."
  }
}
