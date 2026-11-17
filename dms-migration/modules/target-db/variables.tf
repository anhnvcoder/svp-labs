variable "name" {
  description = "Identifier of the DB instance (svp-lab-dms-target), also the name of its subnet group and security group."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-dms-[a-z]{1,20}$", var.name))
    error_message = "name must be svp-lab-dms- followed by 1 to 20 lowercase letters."
  }
}

variable "vpc_id" {
  description = "VPC of the instance (output vpc_id of the network module, AWS side)."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC id such as vpc-0abc..."
  }
}

variable "subnet_ids" {
  description = "Private subnets (output subnet_ids of the network module): RDS requires two availability zones in a subnet group, even for a Single-AZ instance."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "subnet_ids must hold at least two subnets, in two availability zones."
  }
}

variable "availability_zone" {
  description = "Availability zone of the instance: the zone of the DMS instance and of the source, where data transfer is free."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9][a-z]$", var.availability_zone))
    error_message = "availability_zone must be a zone name such as ap-southeast-1a."
  }
}

variable "dms_security_group_id" {
  description = "Security group of the DMS replication instance, let in on 5432."
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]+$", var.dms_security_group_id))
    error_message = "dms_security_group_id must be a security group id such as sg-0abc..."
  }
}

variable "client_cidrs" {
  description = "IPv4 ranges of the on-premises application, let in on 5432 through the peering: the cutover switches its writes here."
  type        = list(string)

  validation {
    condition     = alltrue([for c in var.client_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "client_cidrs must hold IPv4 ranges narrower than 0.0.0.0/0."
  }
}

variable "instance_class" {
  description = "Burstable Graviton class: db.t4g.micro, the smallest class RDS for PostgreSQL offers on Graviton, or db.t4g.small."
  type        = string
  default     = "db.t4g.micro"

  validation {
    condition     = contains(["db.t4g.micro", "db.t4g.small"], var.instance_class)
    error_message = "instance_class must be db.t4g.micro or db.t4g.small."
  }
}

variable "engine_major_version" {
  description = "Major version of PostgreSQL, the same as the source; RDS picks its newest minor."
  type        = string
  default     = "17"

  validation {
    condition     = can(regex("^[0-9]{2}$", var.engine_major_version))
    error_message = "engine_major_version must be a major version such as 17."
  }
}

variable "db_name" {
  description = "Database the instance creates, the migration target."
  type        = string
  default     = "svp_engagement"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.db_name))
    error_message = "db_name must be a PostgreSQL name: a lowercase letter, then up to 62 lowercase letters, digits or underscores."
  }
}

variable "master_username" {
  description = "Master user, the user of the DMS target endpoint and of the application after the cutover."
  type        = string
  default     = "svp_admin"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.master_username))
    error_message = "master_username must be a PostgreSQL name: a lowercase letter, then up to 62 lowercase letters, digits or underscores."
  }
}

variable "master_password" {
  description = "Master password, an ephemeral value (an ephemeral random password of the root). Written only when password_version changes."
  type        = string
  ephemeral   = true
}

variable "password_version" {
  description = "Version of the master password: raising it writes the current master_password. The root passes the same variable to the target secret."
  type        = number

  validation {
    condition     = var.password_version >= 1 && floor(var.password_version) == var.password_version
    error_message = "password_version must be a whole number of at least 1."
  }
}
