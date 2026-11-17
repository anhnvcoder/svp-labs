variable "name" {
  description = "Name of the instance, its security group, IAM role and instance profile, e.g. svp-lab-net-probe-stg. Unique per account: IAM names are global to the account."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 42 lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "vpc_id" {
  description = "ID of the VPC of the instance; for a subnet shared through RAM, the owner's VPC, in which this account creates its own security group."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC ID, e.g. vpc-0123456789abcdef0."
  }
}

variable "subnet_id" {
  description = "ID of the subnet of the instance, possibly a subnet another account shares through RAM."
  type        = string

  validation {
    condition     = can(regex("^subnet-[0-9a-f]+$", var.subnet_id))
    error_message = "subnet_id must be a subnet ID, e.g. subnet-0123456789abcdef0."
  }
}

variable "lab_cidr" {
  description = "IPv4 range of every VPC of the lab, e.g. 10.64.0.0/16: the only source of ping and TCP 80, and the destination of any traffic the probe sends inside the lab."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.lab_cidr)) && var.lab_cidr != "0.0.0.0/0"
    error_message = "lab_cidr must be an IPv4 range other than 0.0.0.0/0, e.g. 10.64.0.0/16."
  }
}
