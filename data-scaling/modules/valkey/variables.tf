variable "name" {
  description = "Prefix of the part (svp-lab-ds-kv): name of the subnet group and user group, of the security group <name>-valkey, and of the secret, user ID and user name <name>-app."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-ds-[a-z]{1,20}$", var.name))
    error_message = "name must be svp-lab-ds- followed by 1 to 20 lowercase letters."
  }
}

variable "vpc_id" {
  description = "VPC of the nodes (output vpc_id of the network module)."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC id such as vpc-0abc..."
  }
}

variable "subnet_ids" {
  description = "The two data subnets, in two availability zones (output data_subnet_ids of the network module): Multi-AZ puts each replica in another zone than its primary."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) == 2 && alltrue([for s in var.subnet_ids : can(regex("^subnet-[0-9a-f]+$", s))])
    error_message = "subnet_ids must hold exactly two subnet ids, in two availability zones."
  }
}

variable "client_security_group_id" {
  description = "Security group of the loader, the only client let in on 6379."
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]+$", var.client_security_group_id))
    error_message = "client_security_group_id must be a security group id such as sg-0abc..."
  }
}

variable "engine_version" {
  description = "Valkey version <major>.<minor> of both groups; ElastiCache applies the patch releases itself. Its major names the default parameter groups default.valkey<major> and default.valkey<major>.cluster.on."
  type        = string
  default     = "9.1"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.engine_version)) && tonumber(split(".", var.engine_version)[0]) >= 8
    error_message = "engine_version must be a Valkey version <major>.<minor> of at least 8.0, such as 9.1."
  }
}

variable "node_type" {
  description = "Node type of every node of both groups: cache.t4g.micro, the smallest Graviton type, or cache.t4g.small."
  type        = string
  default     = "cache.t4g.micro"

  validation {
    condition     = contains(["cache.t4g.micro", "cache.t4g.small"], var.node_type)
    error_message = "node_type must be cache.t4g.micro or cache.t4g.small."
  }
}

variable "shards" {
  description = "Shards (node groups) of svp-lab-ds-cme, each a primary and one replica. The session script reshards through the API; set this to the new count afterwards so that the state matches and the next apply changes nothing."
  type        = number
  default     = 2

  validation {
    condition     = var.shards >= 1 && var.shards <= 5 && floor(var.shards) == var.shards
    error_message = "shards must be a whole number from 1 to 5."
  }
}

variable "password" {
  description = "Password of the user, an ephemeral value (the root's ephemeral random password). Written into the secret only when password_version changes."
  type        = string
  ephemeral   = true
}

variable "user_password" {
  description = "Password the user gets, an ephemeral value the root reads back from the secret's version secret_version_id; sent only when password_version changes."
  type        = string
  ephemeral   = true
}

variable "password_version" {
  description = "Version of the password: raising it writes the current value of password into the secret and sends it to the user."
  type        = number

  validation {
    condition     = var.password_version >= 1 && floor(var.password_version) == var.password_version
    error_message = "password_version must be a whole number of at least 1."
  }
}
