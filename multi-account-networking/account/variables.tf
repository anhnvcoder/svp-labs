variable "management_account_id" {
  description = "ID (12 digits) of the management account, the one account this root works in. Passed as TF_VAR_management_account_id from the terminal variable SVP_AWS_MGMT_ACCOUNT_ID, never written to a file of the repository."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "management_account_id must be the 12 digits of an AWS account id."
  }
}

variable "network_account_email" {
  description = "Email of the root user of svp-network. AWS refuses an address that any account already has, closed accounts included. It is personal data, so it lives only in account.auto.tfvars, which git ignores."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.network_account_email))
    error_message = "network_account_email must be an email address."
  }
}
