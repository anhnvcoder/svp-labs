variable "name" {
  description = "Name of the loader (svp-lab-ds-pg-loader, svp-lab-ds-kv-loader): Name tag of the instance, which the lab's scripts look up, and name of its security group, IAM role and instance profile."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-ds-[a-z]{1,10}-loader$", var.name))
    error_message = "name must be svp-lab-ds-<1 to 10 lowercase letters>-loader."
  }
}

variable "instance_type" {
  description = "Graviton burstable instance type, run in unlimited mode: t4g.small (2 vCPU, 2 GiB) by default, for pgbench with a few hundred short TLS connections and valkey-benchmark."
  type        = string
  default     = "t4g.small"

  validation {
    condition     = contains(["t4g.micro", "t4g.small", "t4g.medium", "t4g.large"], var.instance_type)
    error_message = "instance_type must be t4g.micro, t4g.small, t4g.medium or t4g.large."
  }
}

variable "vpc_id" {
  description = "VPC of the loader (output vpc_id of the network module)."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC id such as vpc-0abc..."
  }
}

variable "vpc_cidr" {
  description = "IPv4 range of the VPC (output vpc_cidr of the network module); the loader may open connections to the data ports inside it."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be an IPv4 range such as 10.67.0.0/20."
  }
}

variable "subnet_id" {
  description = "Public subnet of the loader (output public_subnet_id of the network module)."
  type        = string

  validation {
    condition     = can(regex("^subnet-[0-9a-f]+$", var.subnet_id))
    error_message = "subnet_id must be a subnet id such as subnet-0abc..."
  }
}

variable "secret_arns" {
  description = "ARNs of the Secrets Manager secrets of the loader's part; the role may read these and no other. Empty: no read policy."
  type        = list(string)

  validation {
    condition     = alltrue([for a in var.secret_arns : can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$", a))])
    error_message = "Each of secret_arns must be the ARN of a Secrets Manager secret."
  }
}

variable "data_ports" {
  description = "TCP ports the loader may reach inside the VPC: 5432 for the postgres part, 6379 for the valkey part. Empty: HTTPS only."
  type        = list(number)

  validation {
    condition     = alltrue([for p in var.data_ports : p >= 1 && p <= 65535 && floor(p) == p])
    error_message = "Each of data_ports must be a whole TCP port number between 1 and 65535."
  }
}

variable "user_data" {
  description = "Boot script of the instance: installs the clients and the lab's scripts. Holds no secret: the scripts read them from Secrets Manager at run time. A change replaces the instance."
  type        = string
}
