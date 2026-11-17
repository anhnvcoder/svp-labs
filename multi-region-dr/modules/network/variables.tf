variable "name" {
  description = "Name of the VPC (svp-lab-dr-primary, svp-lab-dr-dr), also the prefix of the Name tag of its subnets and route tables."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-dr-[a-z0-9-]{1,30}$", var.name))
    error_message = "name must start with svp-lab-dr- and go on with 1 to 30 lowercase letters, digits or hyphens."
  }
}

variable "cidr_block" {
  description = "IPv4 range of the VPC, a /20: 10.65.0.0/20 in the primary Region, 10.65.16.0/20 in the DR Region. The module cuts it into /24 subnets: the first for the bastion, the next two for the databases."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr_block, 0)) && try(split("/", var.cidr_block)[1] == "20", false)
    error_message = "cidr_block must be an IPv4 range of prefix length 20, such as 10.65.0.0/20."
  }
}
