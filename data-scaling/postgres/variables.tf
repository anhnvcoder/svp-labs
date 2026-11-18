variable "account_id" {
  description = "Account svp-stg (12 digits), set in the command from the terminal variable: TF_VAR_account_id=$SVP_AWS_STG_ACCOUNT_ID. The provider refuses any other account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12 digits of an AWS account id."
  }
}

variable "aurora" {
  description = "Whether the Aurora PostgreSQL cluster svp-lab-ds-aurora (a writer and a reader) exists. Setting false and applying removes it alone."
  type        = bool
  default     = true
}

variable "rds" {
  description = "Whether the RDS for PostgreSQL Multi-AZ primary svp-lab-ds-rds and its read replica exist. Setting false and applying removes them alone."
  type        = bool
  default     = true
}

variable "proxy" {
  description = "Whether RDS Proxy svp-lab-ds-proxy stands in front of the Aurora cluster; true needs aurora = true."
  type        = bool
  default     = false

  validation {
    condition     = !var.proxy || var.aurora
    error_message = "proxy = true needs aurora = true: the proxy fronts the Aurora cluster."
  }
}

variable "password_version" {
  description = "Version of the master password. Raising it writes a new random password into the secret svp-lab-ds-pg-master and sends that value to Aurora and RDS; a session already holding the old one must read the secret again."
  type        = number
  default     = 1

  validation {
    condition     = var.password_version >= 1 && floor(var.password_version) == var.password_version
    error_message = "password_version must be a whole number of at least 1."
  }
}
