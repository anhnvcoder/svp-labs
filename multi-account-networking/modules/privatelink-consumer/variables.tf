variable "name" {
  description = "Name of the interface endpoint and its security group, e.g. svp-lab-net-svc-stg."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 32 lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "vpc_id" {
  description = "ID of the consumer VPC."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC ID, e.g. vpc-0123456789abcdef0."
  }
}

variable "vpc_cidr" {
  description = "IPv4 range of the consumer VPC, the only source the endpoint admits, e.g. 10.64.32.0/20."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && var.vpc_cidr != "0.0.0.0/0"
    error_message = "vpc_cidr must be an IPv4 range other than 0.0.0.0/0, e.g. 10.64.32.0/20."
  }
}

variable "subnet_id" {
  description = "ID of the subnet of the endpoint's interface; its zone must be one the service is offered in (same zone ID)."
  type        = string

  validation {
    condition     = can(regex("^subnet-[0-9a-f]+$", var.subnet_id))
    error_message = "subnet_id must be a subnet ID, e.g. subnet-0123456789abcdef0."
  }
}

variable "service_name" {
  description = "Name of the endpoint service, e.g. com.amazonaws.vpce.ap-southeast-1.vpce-svc-0123456789abcdef0."
  type        = string

  validation {
    condition     = can(regex("^com\\.amazonaws\\.vpce\\.[a-z0-9-]+\\.vpce-svc-[0-9a-f]+$", var.service_name))
    error_message = "service_name must be the name of an endpoint service of an account, com.amazonaws.vpce.<region>.vpce-svc-<id>."
  }
}

variable "port" {
  description = "TCP port of the service, the only port the endpoint admits."
  type        = number
  default     = 80

  validation {
    condition     = var.port >= 1 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be a TCP port number."
  }
}
