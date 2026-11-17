variable "account_id" {
  description = "Account svp-stg (12 digits), set in the command from the terminal variable: TF_VAR_account_id=$SVP_AWS_STG_ACCOUNT_ID. The provider refuses any other account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12 digits of an AWS account id."
  }
}

variable "rds_ca_bundle" {
  description = "PEM content of https://truststore.pki.rds.amazonaws.com/ap-southeast-1/ap-southeast-1-bundle.pem, set in the command (TF_VAR_rds_ca_bundle=\"$RDS_CA\"): DMS verifies the target against it."
  type        = string

  validation {
    condition     = startswith(trimspace(var.rds_ca_bundle), "-----BEGIN CERTIFICATE-----")
    error_message = "rds_ca_bundle must be the PEM bundle of RDS for ap-southeast-1."
  }
}

variable "create_dms_vpc_role" {
  description = "Whether the lab creates the account-wide role dms-vpc-role. Set false (dms.auto.tfvars) when the account already has it, so the destroy leaves it."
  type        = bool
  default     = true
}

variable "create_dms_logs_role" {
  description = "Whether the lab creates the account-wide role dms-cloudwatch-logs-role. Set false (dms.auto.tfvars) when the account already has it, so the destroy leaves it."
  type        = bool
  default     = true
}

variable "source_password_version" {
  description = "Version of the DMS user's password on the source. Raising it writes a new random password into the SSM parameter and a new value (password and current host) into the source secret; PostgreSQL takes it only from the password command of the README."
  type        = number
  default     = 1

  validation {
    condition     = var.source_password_version >= 1 && floor(var.source_password_version) == var.source_password_version
    error_message = "source_password_version must be a whole number of at least 1."
  }
}

variable "target_password_version" {
  description = "Version of the RDS master password. Raising it writes a new random password into the instance and into the target secret."
  type        = number
  default     = 1

  validation {
    condition     = var.target_password_version >= 1 && floor(var.target_password_version) == var.target_password_version
    error_message = "target_password_version must be a whole number of at least 1."
  }
}
