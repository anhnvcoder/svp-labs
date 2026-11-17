variable "name" {
  description = "Name of the secret (svp-lab-dms-source, svp-lab-dms-target)."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-dms-[a-z0-9-]{1,40}$", var.name))
    error_message = "name must start with svp-lab-dms- and go on with 1 to 40 lowercase letters, digits or hyphens."
  }
}

variable "description" {
  description = "Description of the secret: which database and which user it opens."
  type        = string
}

variable "username" {
  description = "Database user the endpoint connects as."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.username))
    error_message = "username must be a PostgreSQL name: a lowercase letter, then up to 62 lowercase letters, digits or underscores."
  }
}

variable "password" {
  description = "Password of the user, an ephemeral value (an ephemeral random password of the root). Written only when password_version changes."
  type        = string
  ephemeral   = true
}

variable "host" {
  description = "Address of the database server: the private IP address of the on-premises stand-in, or the RDS endpoint address, which its TLS certificate carries."
  type        = string
}

variable "port" {
  description = "Port of the database server."
  type        = number
  default     = 5432

  validation {
    condition     = var.port >= 1 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be a whole number between 1 and 65535."
  }
}

variable "password_version" {
  description = "Version of the value: raising it writes the current password, host and port into the secret. The same variable drives the place that holds the password on the server side, so both always hold the same value."
  type        = number

  validation {
    condition     = var.password_version >= 1 && floor(var.password_version) == var.password_version
    error_message = "password_version must be a whole number of at least 1."
  }
}
