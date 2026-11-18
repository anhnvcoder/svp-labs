variable "name" {
  description = "Identifier of the primary (svp-lab-ds-rds), also the name of its subnet group, the prefix of its replica <name>-replica and of its security group <name>-db."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-ds-[a-z]{1,20}$", var.name))
    error_message = "name must be svp-lab-ds- followed by 1 to 20 lowercase letters."
  }
}

variable "vpc_id" {
  description = "VPC of the instances (output vpc_id of the network module)."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC id such as vpc-0abc..."
  }
}

variable "subnet_ids" {
  description = "The two data subnets, in two availability zones (output data_subnet_ids of the network module): a Multi-AZ instance needs a subnet group in two zones."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) == 2 && alltrue([for s in var.subnet_ids : can(regex("^subnet-[0-9a-f]+$", s))])
    error_message = "subnet_ids must hold exactly two subnet ids, in two availability zones."
  }
}

variable "client_security_group_id" {
  description = "Security group of the loader, the only client let in on 5432."
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]+$", var.client_security_group_id))
    error_message = "client_security_group_id must be a security group id such as sg-0abc..."
  }
}

variable "instance_class" {
  description = "Class of the primary, its standby and the replica: db.t4g.micro, the smallest Graviton class of RDS for PostgreSQL, or db.t4g.small."
  type        = string
  default     = "db.t4g.micro"

  validation {
    condition     = contains(["db.t4g.micro", "db.t4g.small"], var.instance_class)
    error_message = "instance_class must be db.t4g.micro or db.t4g.small."
  }
}

variable "engine_major_version" {
  description = "Major version of PostgreSQL of the primary; RDS picks its newest minor, and the replica follows its source."
  type        = string
  default     = "17"

  validation {
    condition     = can(regex("^[0-9]{2}$", var.engine_major_version))
    error_message = "engine_major_version must be a major version such as 17."
  }
}

variable "db_name" {
  description = "Database the primary creates, where the lab's tables live; the replica carries its source's."
  type        = string
  default     = "svp_lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.db_name))
    error_message = "db_name must be a PostgreSQL name: a lowercase letter, then up to 62 lowercase letters, digits or underscores."
  }
}

variable "master_username" {
  description = "Master user of the primary, the username of the part's secret; the replica carries its source's."
  type        = string
  default     = "svp_admin"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.master_username))
    error_message = "master_username must be a PostgreSQL name: a lowercase letter, then up to 62 lowercase letters, digits or underscores."
  }
}

variable "master_password" {
  description = "Master password of the primary, an ephemeral value read back from the part's secret. Sent only when password_version changes."
  type        = string
  ephemeral   = true
}

variable "password_version" {
  description = "Version of the master password, the same variable as the secret's: raising it sends the current master_password."
  type        = number

  validation {
    condition     = var.password_version >= 1 && floor(var.password_version) == var.password_version
    error_message = "password_version must be a whole number of at least 1."
  }
}
