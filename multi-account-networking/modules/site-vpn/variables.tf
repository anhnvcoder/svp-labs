variable "name" {
  description = "Name of the VPN connection and its customer gateway, e.g. svp-lab-net-vpn."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 32 lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "transit_gateway_id" {
  description = "ID of the transit gateway the VPN connection attaches to, in this account."
  type        = string

  validation {
    condition     = can(regex("^tgw-[0-9a-f]+$", var.transit_gateway_id))
    error_message = "transit_gateway_id must be a transit gateway ID, e.g. tgw-0123456789abcdef0."
  }
}

variable "site_cidr" {
  description = "IPv4 range of the site, e.g. 192.168.0.0/20: the local traffic selector of the tunnels and the destination of the transit gateway routes."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.site_cidr)) && var.site_cidr != "0.0.0.0/0"
    error_message = "site_cidr must be an IPv4 range other than 0.0.0.0/0, e.g. 192.168.0.0/20."
  }
}

variable "lab_cidr" {
  description = "IPv4 range of the lab's VPCs, e.g. 10.64.0.0/16: the remote traffic selector of the tunnels."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.lab_cidr)) && var.lab_cidr != "0.0.0.0/0"
    error_message = "lab_cidr must be an IPv4 range other than 0.0.0.0/0, e.g. 10.64.0.0/16."
  }
}

variable "association_route_table_id" {
  description = "ID of the transit gateway route table the VPN attachment is associated with: where traffic from the site is looked up."
  type        = string

  validation {
    condition     = can(regex("^tgw-rtb-[0-9a-f]+$", var.association_route_table_id))
    error_message = "association_route_table_id must be a transit gateway route table ID."
  }
}

variable "routed_route_table_ids" {
  description = "Route tables, under a key known before apply, whose attachments reach the site: each gets site_cidr to the VPN attachment, e.g. { nonprd = <ID> }."
  type        = map(string)

  validation {
    condition     = length(var.routed_route_table_ids) > 0 && alltrue([for id in values(var.routed_route_table_ids) : can(regex("^tgw-rtb-[0-9a-f]+$", id))])
    error_message = "routed_route_table_ids must hold at least one transit gateway route table ID."
  }
}

variable "blackholed_route_table_ids" {
  description = "Route tables, under a key known before apply, whose attachments must not reach the site: each gets a blackhole for site_cidr, e.g. { prd = <ID> }."
  type        = map(string)

  validation {
    condition     = alltrue([for id in values(var.blackholed_route_table_ids) : can(regex("^tgw-rtb-[0-9a-f]+$", id))])
    error_message = "Each value of blackholed_route_table_ids must be a transit gateway route table ID."
  }

  validation {
    condition     = length(setintersection(keys(var.blackholed_route_table_ids), keys(var.routed_route_table_ids))) == 0
    error_message = "A route table cannot both reach the site and blackhole it."
  }
}
