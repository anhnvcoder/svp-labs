variable "name" {
  description = "Name of the secret (svp-lab-ds-pg-master)."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-ds-[a-z0-9-]{1,40}$", var.name))
    error_message = "name must start with svp-lab-ds- and go on with 1 to 40 lowercase letters, digits or hyphens."
  }
}

variable "username" {
  description = "Master user name of the databases, the username key of the secret."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.username))
    error_message = "username must be a PostgreSQL name: a lowercase letter, then up to 62 lowercase letters, digits or underscores."
  }
}

variable "password" {
  description = "The password, an ephemeral value (the root's ephemeral random password). Written only when password_version changes."
  type        = string
  ephemeral   = true
}

variable "password_version" {
  description = "Version of the password: raising it writes the current value of password into the secret."
  type        = number

  validation {
    condition     = var.password_version >= 1 && floor(var.password_version) == var.password_version
    error_message = "password_version must be a whole number of at least 1."
  }
}
