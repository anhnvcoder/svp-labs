variable "name" {
  description = "Name of the VPC and prefix of the names of its subnets and route tables (<name>-workload, <name>-tgw), e.g. svp-lab-net-stg."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 32 lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "cidr" {
  description = "IPv4 range of the VPC, a /16 to /20: the workload subnet is its first /24 and the attachment subnet the /28 that follows it."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.cidr)) && tonumber(split("/", var.cidr)[1]) >= 16 && tonumber(split("/", var.cidr)[1]) <= 20
    error_message = "cidr must be an IPv4 range from /16 to /20, e.g. 10.64.32.0/20."
  }
}

variable "availability_zone_id" {
  description = "Zone of both subnets, by zone ID (e.g. apse1-az1): zone names map to different zones in each account, zone IDs do not, so every VPC of the lab sits in the same zone."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+[0-9]-az[0-9]+$", var.availability_zone_id))
    error_message = "availability_zone_id must be a zone ID such as apse1-az1."
  }
}

variable "transit_gateway_id" {
  description = "ID of the transit gateway the VPC attaches to: the hub of the network account, shared with this account through RAM when the VPC lives elsewhere."
  type        = string

  validation {
    condition     = can(regex("^tgw-[0-9a-f]+$", var.transit_gateway_id))
    error_message = "transit_gateway_id must be a transit gateway ID, e.g. tgw-0123456789abcdef0."
  }
}

variable "transit_gateway_in_same_account" {
  description = "true when the transit gateway belongs to the VPC's own account. The attachment then states that it joins no default route table; for a transit gateway shared through RAM the provider refuses that setting."
  type        = bool
}
