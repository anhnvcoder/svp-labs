variable "name" {
  description = "Name of the bastion (svp-lab-dr-bastion-primary, svp-lab-dr-bastion-dr): Name tag of the instance, which the lab's scripts look up, and name of its security group, IAM role and instance profile."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-dr-bastion-[a-z]{1,10}$", var.name))
    error_message = "name must be svp-lab-dr-bastion- followed by 1 to 10 lowercase letters."
  }
}

variable "instance_type" {
  description = "Graviton instance type: t4g.micro (1 GiB) by default; t4g.nano has 0.5 GiB for dnf, which installs the PostgreSQL client at boot."
  type        = string
  default     = "t4g.micro"

  validation {
    condition     = contains(["t4g.nano", "t4g.micro"], var.instance_type)
    error_message = "instance_type must be t4g.nano or t4g.micro."
  }
}

variable "vpc_id" {
  description = "VPC of the bastion (output vpc_id of the network module)."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC id such as vpc-0abc..."
  }
}

variable "vpc_cidr" {
  description = "IPv4 range of the VPC (output vpc_cidr of the network module); the bastion may open PostgreSQL connections inside it."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be an IPv4 range such as 10.65.0.0/20."
  }
}

variable "subnet_id" {
  description = "Public subnet of the bastion (output public_subnet_id of the network module)."
  type        = string

  validation {
    condition     = can(regex("^subnet-[0-9a-f]+$", var.subnet_id))
    error_message = "subnet_id must be a subnet id such as subnet-0abc..."
  }
}

variable "secret_arn" {
  description = "ARN of the Secrets Manager secret that holds the database password in the bastion's Region: the primary secret in the primary Region, its replica in the DR Region."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$", var.secret_arn))
    error_message = "secret_arn must be the ARN of a Secrets Manager secret."
  }
}

variable "user_data" {
  description = "Boot script of the instance: installs the PostgreSQL client, dig, the RDS certificate bundle and the heartbeat script. Holds no secret: the script reads the password from Secrets Manager at run time. A change replaces the instance."
  type        = string
}
