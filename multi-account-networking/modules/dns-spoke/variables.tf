variable "name" {
  description = "Name of the Profile association, e.g. svp-lab-net-stg."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 32 lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "vpc_id" {
  description = "ID of the spoke VPC that receives the DNS settings."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC ID, e.g. vpc-0123456789abcdef0."
  }
}

variable "profile_id" {
  description = "ID of the Route 53 Profile of the network account, shared with this account through RAM."
  type        = string

  validation {
    condition     = can(regex("^rp-[0-9a-z]+$", var.profile_id))
    error_message = "profile_id must be a Route 53 Profile ID, e.g. rp-0123456789abcdef."
  }
}

variable "zone_ids" {
  description = "Private hosted zones of another account whose owner authorized this VPC, under a key known before apply, e.g. { nonprd = <zone ID> }. Empty: the VPC gets its zones from the Profile only."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for z in values(var.zone_ids) : can(regex("^Z[0-9A-Z]+$", z))])
    error_message = "Each value of zone_ids must be a hosted zone ID, e.g. Z0123456789ABCDEFGHIJ."
  }
}
