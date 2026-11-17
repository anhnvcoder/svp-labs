variable "account_id" {
  description = "Account svp-stg (12 digits), set in the command from the terminal variable: TF_VAR_account_id=$SVP_AWS_STG_ACCOUNT_ID. The provider refuses any other account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12 digits of an AWS account id."
  }
}
