variable "name" {
  description = "Name of the instance (svp-lab-dms-source): Name tag, which the lab's scripts look up, and name of its security group, IAM role and instance profile."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-dms-[a-z]{1,20}$", var.name))
    error_message = "name must be svp-lab-dms- followed by 1 to 20 lowercase letters."
  }
}

variable "instance_type" {
  description = "Graviton instance type: t4g.micro (1 GiB) by default, enough for PostgreSQL with the sample tables; t4g.nano has 0.5 GiB."
  type        = string
  default     = "t4g.micro"

  validation {
    condition     = contains(["t4g.nano", "t4g.micro"], var.instance_type)
    error_message = "instance_type must be t4g.nano or t4g.micro."
  }
}

variable "vpc_id" {
  description = "VPC of the on-premises stand-in (output vpc_id of the network module)."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC id such as vpc-0abc..."
  }
}

variable "subnet_id" {
  description = "Public subnet of the instance (first of subnet_ids of the network module)."
  type        = string

  validation {
    condition     = can(regex("^subnet-[0-9a-f]+$", var.subnet_id))
    error_message = "subnet_id must be a subnet id such as subnet-0abc..."
  }
}

variable "dms_cidrs" {
  description = "IPv4 ranges of the DMS subnets, the only clients let in on 5432 (pg_hba.conf of the boot script lists the same ranges)."
  type        = list(string)

  validation {
    condition     = length(var.dms_cidrs) >= 1 && alltrue([for c in var.dms_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "dms_cidrs must hold at least one IPv4 range narrower than 0.0.0.0/0."
  }
}

variable "target_cidr" {
  description = "IPv4 range of the AWS side, where the application writes after the cutover."
  type        = string

  validation {
    condition     = can(cidrhost(var.target_cidr, 0)) && var.target_cidr != "0.0.0.0/0"
    error_message = "target_cidr must be an IPv4 range narrower than 0.0.0.0/0."
  }
}

variable "password_parameter_name" {
  description = "Name of the SSM parameter holding the password of the DMS user (/svp-lab-dms/...)."
  type        = string

  validation {
    condition     = can(regex("^/svp-lab-dms/[a-z0-9/_-]+$", var.password_parameter_name))
    error_message = "password_parameter_name must be a path under /svp-lab-dms/."
  }
}

variable "password" {
  description = "Password of the DMS user, an ephemeral value (an ephemeral random password of the root). Written only when password_version changes."
  type        = string
  ephemeral   = true
}

variable "password_version" {
  description = "Version of the password: raising it writes the current password into the parameter. The root passes the same variable to the source secret; the running PostgreSQL takes the new value only through the password command of the README."
  type        = number

  validation {
    condition     = var.password_version >= 1 && floor(var.password_version) == var.password_version
    error_message = "password_version must be a whole number of at least 1."
  }
}

variable "target_secret_arn" {
  description = "ARN of the secret of the target, which the application reads after the cutover."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$", var.target_secret_arn))
    error_message = "target_secret_arn must be the ARN of a Secrets Manager secret."
  }
}

variable "task_arn" {
  description = "ARN of the DMS replication task whose validation the cutover waits for and which it stops."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:dms:[a-z0-9-]+:[0-9]{12}:task:[A-Za-z0-9]+$", var.task_arn))
    error_message = "task_arn must be the ARN of a DMS replication task."
  }
}

variable "user_data" {
  description = "Boot script: installs PostgreSQL, sets it up for logical replication and TLS, installs the lab script and creates the DMS user with the parameter's password. Holds no secret. A change replaces the instance, and with it the source database."
  type        = string
}
