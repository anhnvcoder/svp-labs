variable "name" {
  description = "Name of the lab (svp-lab-dr): namespace of the switch metric, prefix of the alarm <name>-failover and of the Name tag of the health check."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-dr$", var.name))
    error_message = "name must be svp-lab-dr: the drill script writes the metric of that namespace."
  }
}

variable "zone_name" {
  description = "Name of the private hosted zone; the record is db.<zone_name>. Any name works inside the VPCs, no domain is registered."
  type        = string
  default     = "svp-lab-dr.internal"

  validation {
    condition     = can(regex("^[a-z0-9-]+(\\.[a-z0-9-]+)+$", var.zone_name))
    error_message = "zone_name must be a DNS name of lowercase labels such as svp-lab-dr.internal."
  }
}

variable "vpcs" {
  description = "VPCs the zone answers in, each with its Region: the VPC of the primary Region and the VPC of the DR Region."
  type = list(object({
    vpc_id = string
    region = string
  }))

  validation {
    condition     = length(var.vpcs) >= 1 && alltrue([for v in var.vpcs : can(regex("^vpc-[0-9a-f]+$", v.vpc_id)) && contains(["ap-southeast-1", "us-east-1"], v.region)])
    error_message = "vpcs must hold at least one VPC id, each in ap-southeast-1 or us-east-1."
  }
}

variable "primary_target" {
  description = "Host name of the primary DB instance, the answer while the switch is up."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9.-]+$", var.primary_target))
    error_message = "primary_target must be a host name."
  }
}

variable "secondary_target" {
  description = "Host name of the DR DB instance (the replica, promoted by the drill), the answer once the switch is down."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9.-]+$", var.secondary_target))
    error_message = "secondary_target must be a host name."
  }
}

variable "ttl" {
  description = "Seconds resolvers may cache the answer. Part of the measured RTO: a client sees the DR instance at most this long after Route 53 switches."
  type        = number
  default     = 10

  validation {
    condition     = var.ttl >= 1 && var.ttl <= 300 && floor(var.ttl) == var.ttl
    error_message = "ttl must be a whole number of seconds from 1 to 300."
  }
}
