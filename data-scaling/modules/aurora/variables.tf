variable "name" {
  description = "Identifier of the cluster (svp-lab-ds-aurora), also the name of its subnet group, the prefix of its instances <name>-1 and <name>-2 and of its security group <name>-db."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-ds-[a-z]{1,20}$", var.name))
    error_message = "name must be svp-lab-ds- followed by 1 to 20 lowercase letters."
  }
}

variable "vpc_id" {
  description = "VPC of the cluster (output vpc_id of the network module)."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC id such as vpc-0abc..."
  }
}

variable "subnet_ids" {
  description = "The two data subnets, in two availability zones (output data_subnet_ids of the network module): the writer goes to the first, the reader to the second."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) == 2 && alltrue([for s in var.subnet_ids : can(regex("^subnet-[0-9a-f]+$", s))])
    error_message = "subnet_ids must hold exactly two subnet ids, in two availability zones."
  }
}

variable "client_security_group_ids" {
  description = "Security groups let in on 5432, by a name for the rule's description: the loader, and the proxy when there is one. Keys are fixed words so that the set of rules is known at plan time."
  type        = map(string)

  validation {
    condition     = length(var.client_security_group_ids) > 0 && alltrue([for k, v in var.client_security_group_ids : can(regex("^[a-z]{1,20}$", k)) && can(regex("^sg-[0-9a-f]+$", v))])
    error_message = "client_security_group_ids must map at least one lowercase word to a security group id such as sg-0abc..."
  }
}

variable "instance_class" {
  description = "Class of both instances: db.t4g.medium, the smallest class Aurora PostgreSQL 17 offers, or db.t4g.large."
  type        = string
  default     = "db.t4g.medium"

  validation {
    condition     = contains(["db.t4g.medium", "db.t4g.large"], var.instance_class)
    error_message = "instance_class must be db.t4g.medium or db.t4g.large."
  }
}

variable "engine_major_version" {
  description = "Major version of Aurora PostgreSQL; the cluster takes its newest minor."
  type        = string
  default     = "17"

  validation {
    condition     = can(regex("^[0-9]{2}$", var.engine_major_version))
    error_message = "engine_major_version must be a major version such as 17."
  }
}

variable "db_name" {
  description = "Database the cluster creates, where the lab's tables live."
  type        = string
  default     = "svp_lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.db_name))
    error_message = "db_name must be a PostgreSQL name: a lowercase letter, then up to 62 lowercase letters, digits or underscores."
  }
}

variable "master_username" {
  description = "Master user of the cluster, the username of the part's secret."
  type        = string
  default     = "svp_admin"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.master_username))
    error_message = "master_username must be a PostgreSQL name: a lowercase letter, then up to 62 lowercase letters, digits or underscores."
  }
}

variable "master_password" {
  description = "Master password, an ephemeral value read back from the part's secret. Sent only when password_version changes."
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
