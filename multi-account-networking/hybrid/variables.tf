variable "network_account_id" {
  description = "The account svp-network (12 digits), output network_account_id of the root account. Set it with TF_VAR_network_account_id from SVP_AWS_NETWORK_ACCOUNT_ID."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.network_account_id))
    error_message = "network_account_id must be the 12 digits of an AWS account id."
  }
}

variable "stg_account_id" {
  description = "The account svp-stg (12 digits). Set it with TF_VAR_stg_account_id from SVP_AWS_STG_ACCOUNT_ID."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.stg_account_id))
    error_message = "stg_account_id must be the 12 digits of an AWS account id."
  }
}

variable "prd_account_id" {
  description = "The account svp-prd (12 digits). Set it with TF_VAR_prd_account_id from SVP_AWS_PRD_ACCOUNT_ID."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.prd_account_id))
    error_message = "prd_account_id must be the 12 digits of an AWS account id."
  }
}

variable "availability_zone_id" {
  description = "The one zone of every VPC, by zone ID, the same physical zone in every account. The same value as for the root core: the site and the Resolver subnet sit in the zone of the lab's attachments."
  type        = string
  default     = "apse1-az1"

  validation {
    condition     = can(regex("^apse1-az[0-9]+$", var.availability_zone_id))
    error_message = "availability_zone_id must be a zone ID of ap-southeast-1, e.g. apse1-az1."
  }
}
