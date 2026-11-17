variable "name" {
  description = "Name of the Route 53 Profile and prefix of its resource associations, e.g. svp-lab-net."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 32 lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "vpc_id" {
  description = "ID of the VPC of this account that both private zones are created with (the shared VPC of the lab)."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC ID, e.g. vpc-0123456789abcdef0."
  }
}

variable "records" {
  description = "A records per zone: zone key (net or nonprd), then host name to IPv4 address, e.g. { net = { shared-probe = \"10.64.16.10\" } } for shared-probe.net.svp.example."
  type        = map(map(string))

  validation {
    condition     = alltrue([for z in keys(var.records) : contains(["net", "nonprd"], z)])
    error_message = "records may only use the zone keys net and nonprd."
  }

  validation {
    condition = alltrue(flatten([for hosts in values(var.records) : [
      for h, ip in hosts : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", h)) && can(cidrhost("${ip}/32", 0))
    ]]))
    error_message = "Each host must be a DNS label (lowercase letters, digits, dashes) and each address an IPv4 address."
  }
}

variable "nonprd_vpc_ids" {
  description = "VPCs of other accounts, under a key known before apply, that may associate themselves with the zone nonprd.svp.example (the zone owner's authorization), e.g. { stg = <VPC ID> }."
  type        = map(string)

  validation {
    condition     = alltrue([for v in values(var.nonprd_vpc_ids) : can(regex("^vpc-[0-9a-f]+$", v))])
    error_message = "Each value of nonprd_vpc_ids must be a VPC ID."
  }
}
