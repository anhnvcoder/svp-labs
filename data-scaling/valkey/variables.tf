variable "account_id" {
  description = "Account svp-stg (12 digits), set in the command from the terminal variable: TF_VAR_account_id=$SVP_AWS_STG_ACCOUNT_ID. The provider refuses any other account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12 digits of an AWS account id."
  }
}

variable "shards" {
  description = "Shards of svp-lab-ds-cme. kv-session.sh reshard changes the count through the API; set this to the new count after it, so that the state matches and the next plan shows no change."
  type        = number
  default     = 2

  validation {
    condition     = var.shards >= 1 && var.shards <= 5 && floor(var.shards) == var.shards
    error_message = "shards must be a whole number from 1 to 5."
  }
}

variable "password_version" {
  description = "Version of the password of the Valkey user. Raising it writes a new random password into the secret svp-lab-ds-kv-app and sends that value to the user; kv.sh reads the secret again at each run."
  type        = number
  default     = 1

  validation {
    condition     = var.password_version >= 1 && floor(var.password_version) == var.password_version
    error_message = "password_version must be a whole number of at least 1."
  }
}
