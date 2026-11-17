variable "bucket_name" {
  description = "Name of the upload bucket, svp-lab-sls-uploads-<account>-<region>, computed by the root from the account and Region at run time."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-sls-[a-z0-9-]{1,51}$", var.bucket_name)) && !endswith(var.bucket_name, "-")
    error_message = "bucket_name must start with svp-lab-sls-, hold only lowercase letters, digits and hyphens, end with a letter or digit and be at most 63 characters."
  }
}

variable "function_arn" {
  description = "Unqualified ARN of the transcode function the state machine invokes."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:lambda:[a-z0-9-]+:[0-9]{12}:function:svp-lab-sls-[a-z0-9-]+$", var.function_arn))
    error_message = "function_arn must be the unqualified ARN of a function of the lab (svp-lab-sls-...)."
  }
}
