variable "name" {
  description = "Identifier of the replication instance and of the task (svp-lab-dms), prefix of the endpoints, security groups, certificate and role; the task log group is dms-tasks-<name>."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-dms(-[a-z]{1,20})?$", var.name))
    error_message = "name must be svp-lab-dms, optionally followed by a hyphen and 1 to 20 lowercase letters."
  }
}

variable "vpc_id" {
  description = "VPC of the AWS side (output vpc_id of the network module)."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC id such as vpc-0abc..."
  }
}

variable "subnet_ids" {
  description = "Private subnets of the AWS side (output subnet_ids of the network module): a DMS subnet group needs two zones. The first one, in availability_zone, also holds the Secrets Manager endpoint."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "subnet_ids must hold at least two subnets, in two availability zones."
  }
}

variable "availability_zone" {
  description = "Availability zone of the replication instance, the zone of the first subnet, of the source and of the target."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9][a-z]$", var.availability_zone))
    error_message = "availability_zone must be a zone name such as ap-southeast-1a."
  }
}

variable "source_cidrs" {
  description = "IPv4 ranges where the on-premises source listens, reached through the peering."
  type        = list(string)

  validation {
    condition     = length(var.source_cidrs) >= 1 && alltrue([for c in var.source_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "source_cidrs must hold at least one IPv4 range narrower than 0.0.0.0/0."
  }
}

variable "target_cidr" {
  description = "IPv4 range of the AWS-side VPC, where the RDS target listens."
  type        = string

  validation {
    condition     = can(cidrhost(var.target_cidr, 0)) && var.target_cidr != "0.0.0.0/0"
    error_message = "target_cidr must be an IPv4 range narrower than 0.0.0.0/0."
  }
}

variable "create_vpc_role" {
  description = "Whether to create the account-wide role dms-vpc-role. False when the account already has it (the README checks first); the lab then never deletes it."
  type        = bool
  default     = true
}

variable "create_logs_role" {
  description = "Whether to create the account-wide role dms-cloudwatch-logs-role. False when the account already has it (the README checks first); the lab then never deletes it."
  type        = bool
  default     = true
}

variable "instance_class" {
  description = "Class of the replication instance: dms.t3.micro (1 GiB) by default; dms.t3.small or dms.t3.medium when FreeableMemory runs low under the load."
  type        = string
  default     = "dms.t3.micro"

  validation {
    condition     = contains(["dms.t3.micro", "dms.t3.small", "dms.t3.medium"], var.instance_class)
    error_message = "instance_class must be dms.t3.micro, dms.t3.small or dms.t3.medium."
  }
}

variable "allocated_storage" {
  description = "Storage of the replication instance in GiB, for its logs and the changes it caches during the full load."
  type        = number
  default     = 20

  validation {
    condition     = var.allocated_storage >= 5 && var.allocated_storage <= 100 && floor(var.allocated_storage) == var.allocated_storage
    error_message = "allocated_storage must be a whole number of GiB between 5 and 100."
  }
}

variable "engine_version" {
  description = "Replication engine version: 3.6.1 or a later 3.6 release, the first to validate tables whose primary key is a PostgreSQL uuid."
  type        = string
  default     = "3.6.1"

  validation {
    condition     = can(regex("^3\\.6\\.[1-9][0-9]*$", var.engine_version))
    error_message = "engine_version must be 3.6.1 or a later 3.6 release."
  }
}

variable "database_name" {
  description = "Database migrated, the same name on both sides."
  type        = string
  default     = "svp_engagement"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.database_name))
    error_message = "database_name must be a PostgreSQL name: a lowercase letter, then up to 62 lowercase letters, digits or underscores."
  }
}

variable "tables" {
  description = "Tables of schema public the task migrates; each has a primary key, which CDC and validation need."
  type        = list(string)
  default     = ["view_counts", "likes", "heartbeat"]

  validation {
    condition     = length(var.tables) >= 1 && alltrue([for t in var.tables : can(regex("^[a-z][a-z0-9_]{0,62}$", t))])
    error_message = "tables must hold at least one PostgreSQL table name in lowercase."
  }
}

variable "source_secret_arn" {
  description = "ARN of the secret of the source endpoint (username, password, host, port)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$", var.source_secret_arn))
    error_message = "source_secret_arn must be the ARN of a Secrets Manager secret."
  }
}

variable "target_secret_arn" {
  description = "ARN of the secret of the target endpoint (username, password, host, port)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$", var.target_secret_arn))
    error_message = "target_secret_arn must be the ARN of a Secrets Manager secret."
  }
}

variable "rds_ca_bundle" {
  description = "PEM content of the RDS certificate bundle of the Region (https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem), imported as the DMS certificate of the target endpoint."
  type        = string

  validation {
    condition     = startswith(trimspace(var.rds_ca_bundle), "-----BEGIN CERTIFICATE-----") && endswith(trimspace(var.rds_ca_bundle), "-----END CERTIFICATE-----")
    error_message = "rds_ca_bundle must be PEM certificates, from -----BEGIN CERTIFICATE----- to -----END CERTIFICATE-----."
  }
}
