variable "account_id" {
  description = "Account svp-stg (12 digits), set in the command from the terminal variable: TF_VAR_account_id=$SVP_AWS_STG_ACCOUNT_ID. Both providers refuse any other account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12 digits of an AWS account id."
  }
}

variable "password_version" {
  description = "Version of the database master password. Raising it writes a new random password into the primary instance and into the secret; a client that read the old one reads the secret again."
  type        = number
  default     = 1

  validation {
    condition     = var.password_version >= 1 && floor(var.password_version) == var.password_version
    error_message = "password_version must be a whole number of at least 1."
  }
}
