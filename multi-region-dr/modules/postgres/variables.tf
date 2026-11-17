variable "name" {
  description = "Identifier of the DB instance (svp-lab-dr-primary, svp-lab-dr-replica), also the name of its subnet group and the prefix of its security group <name>-db, which the drill script looks up."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-dr-[a-z]{1,20}$", var.name))
    error_message = "name must be svp-lab-dr- followed by 1 to 20 lowercase letters."
  }
}

variable "vpc_id" {
  description = "VPC of the instance (output vpc_id of the network module)."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC id such as vpc-0abc..."
  }
}

variable "subnet_ids" {
  description = "Database subnets (output db_subnet_ids of the network module): RDS requires two availability zones in a subnet group, even for a Single-AZ instance."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "subnet_ids must hold at least two subnets, in two availability zones."
  }
}

variable "client_security_group_id" {
  description = "Security group of the bastion of the same Region, the only client let in on 5432."
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]+$", var.client_security_group_id))
    error_message = "client_security_group_id must be a security group id such as sg-0abc..."
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
  description = "Major version of PostgreSQL of the primary; RDS picks its newest minor, and a replica follows its source."
  type        = string
  default     = "17"

  validation {
    condition     = can(regex("^[0-9]{2}$", var.engine_major_version))
    error_message = "engine_major_version must be a major version such as 17."
  }
}

variable "replicate_source_db" {
  description = "ARN of the source instance when this instance is its read replica in another Region; null for the primary."
  type        = string
  default     = null

  validation {
    condition     = var.replicate_source_db == null || can(regex("^arn:aws[a-z-]*:rds:[a-z0-9-]+:[0-9]{12}:db:[a-z0-9-]+$", var.replicate_source_db))
    error_message = "replicate_source_db must be the ARN of a DB instance (a cross-Region replica names its source by ARN)."
  }
}

variable "kms_key_arn" {
  description = "ARN of the aws/rds key of this instance's Region. Required for a replica and for replicated backups (RDS needs a key of the destination Region for encrypted copies); null for the primary, which then uses aws/rds of its Region."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null ? var.replicate_source_db == null && var.replicate_backups_from == null : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.kms_key_arn))
    error_message = "kms_key_arn must be the ARN of a KMS key, and is required with replicate_source_db or replicate_backups_from."
  }
}

variable "db_name" {
  description = "Database the primary creates, where the heartbeat table of the lab lives; a replica carries its source's."
  type        = string
  default     = "svp_lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.db_name))
    error_message = "db_name must be a PostgreSQL name: a lowercase letter, then up to 62 lowercase letters, digits or underscores."
  }
}

variable "master_username" {
  description = "Master user of the primary; a replica carries its source's."
  type        = string
  default     = "svp_admin"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.master_username))
    error_message = "master_username must be a PostgreSQL name: a lowercase letter, then up to 62 lowercase letters, digits or underscores."
  }
}

variable "master_password" {
  description = "Master password of the primary, an ephemeral value (the root's ephemeral random password); unused for a replica, which takes its source's."
  type        = string
  default     = null
  ephemeral   = true
}

variable "password_version" {
  description = "Version of the master password of the primary: raising it writes the current master_password. Required for the primary, unused for a replica."
  type        = number
  default     = null

  validation {
    condition     = var.replicate_source_db != null || try(var.password_version >= 1 && floor(var.password_version) == var.password_version, false)
    error_message = "password_version must be a whole number of at least 1 for the primary."
  }
}

variable "backup_retention_period" {
  description = "Days of automated backups of the primary: at least 1, since a replica and the backup replication both need them."
  type        = number
  default     = 1

  validation {
    condition     = var.backup_retention_period >= 1 && var.backup_retention_period <= 35
    error_message = "backup_retention_period must be between 1 and 35 days."
  }
}

variable "replicate_backups_from" {
  description = "ARN of an instance in another Region whose automated backups RDS replicates into this Region (the backup and restore path); null replicates nothing."
  type        = string
  default     = null

  validation {
    condition     = var.replicate_backups_from == null || can(regex("^arn:aws[a-z-]*:rds:[a-z0-9-]+:[0-9]{12}:db:[a-z0-9-]+$", var.replicate_backups_from))
    error_message = "replicate_backups_from must be the ARN of a DB instance."
  }
}

variable "replicated_backup_retention_days" {
  description = "Days RDS keeps the replicated backups, the window of a point-in-time restore in this Region."
  type        = number
  default     = 1

  validation {
    condition     = var.replicated_backup_retention_days >= 1 && var.replicated_backup_retention_days <= 35
    error_message = "replicated_backup_retention_days must be between 1 and 35 days."
  }
}
