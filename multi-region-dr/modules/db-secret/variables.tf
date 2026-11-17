variable "name" {
  description = "Name of the secret, the same in both Regions (svp-lab-dr-db-master)."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-dr-[a-z0-9-]{1,40}$", var.name))
    error_message = "name must start with svp-lab-dr- and go on with 1 to 40 lowercase letters, digits or hyphens."
  }
}

variable "replica_region" {
  description = "Region that holds the replica of the secret: the DR Region, us-east-1."
  type        = string

  validation {
    condition     = contains(["ap-southeast-1", "us-east-1"], var.replica_region)
    error_message = "replica_region must be ap-southeast-1 or us-east-1, the only Regions the organization allows."
  }
}

variable "password" {
  description = "The password, an ephemeral value (the root's ephemeral random password). Written only when password_version changes."
  type        = string
  ephemeral   = true
}

variable "password_version" {
  description = "Version of the password: raising it writes the current value of password into the secret. The same variable drives password_wo_version of the primary DB instance, so both always hold the same value."
  type        = number

  validation {
    condition     = var.password_version >= 1 && floor(var.password_version) == var.password_version
    error_message = "password_version must be a whole number of at least 1."
  }
}
