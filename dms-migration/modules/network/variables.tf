variable "name" {
  description = "Name of the VPC (svp-lab-dms-onprem, svp-lab-dms-aws), also the prefix of the Name tag of its subnets and route table."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-dms-[a-z]{1,20}$", var.name))
    error_message = "name must be svp-lab-dms- followed by 1 to 20 lowercase letters."
  }
}

variable "cidr_block" {
  description = "IPv4 range of the VPC, a /20: 192.168.16.0/20 for the on-premises stand-in, 10.66.0.0/20 for the AWS side. The module cuts it into /24 subnets from the first one."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr_block, 0)) && try(split("/", var.cidr_block)[1] == "20", false)
    error_message = "cidr_block must be an IPv4 range of prefix length 20, such as 10.66.0.0/20."
  }
}

variable "subnets" {
  description = "Kind of subnets: public (one subnet in the first availability zone, routed to an internet gateway) or private (two subnets in two availability zones, no route out of the VPC)."
  type        = string

  validation {
    condition     = contains(["public", "private"], var.subnets)
    error_message = "subnets must be public or private."
  }
}
