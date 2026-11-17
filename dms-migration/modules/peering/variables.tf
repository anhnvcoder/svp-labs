variable "name" {
  description = "Name tag of the peering connection (svp-lab-dms-peering)."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-dms-[a-z0-9-]{1,30}$", var.name))
    error_message = "name must start with svp-lab-dms- and go on with 1 to 30 lowercase letters, digits or hyphens."
  }
}

variable "requester" {
  description = "VPC that requests the peering (the on-premises stand-in): its id, IPv4 range and the route table of its subnets."
  type = object({
    vpc_id         = string
    cidr           = string
    route_table_id = string
  })

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.requester.vpc_id)) && can(cidrhost(var.requester.cidr, 0)) && can(regex("^rtb-[0-9a-f]+$", var.requester.route_table_id))
    error_message = "requester needs a VPC id (vpc-...), an IPv4 range and a route table id (rtb-...)."
  }
}

variable "accepter" {
  description = "VPC that accepts the peering (the AWS side), in the same account and Region: its id, IPv4 range and the route table of its subnets."
  type = object({
    vpc_id         = string
    cidr           = string
    route_table_id = string
  })

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.accepter.vpc_id)) && can(cidrhost(var.accepter.cidr, 0)) && can(regex("^rtb-[0-9a-f]+$", var.accepter.route_table_id))
    error_message = "accepter needs a VPC id (vpc-...), an IPv4 range and a route table id (rtb-...)."
  }

  # Peering refuses VPCs whose ranges overlap; the cheap check here catches the same range given twice.
  validation {
    condition     = var.accepter.cidr != var.requester.cidr && var.accepter.vpc_id != var.requester.vpc_id
    error_message = "accepter and requester must be two different VPCs with two different ranges."
  }
}
