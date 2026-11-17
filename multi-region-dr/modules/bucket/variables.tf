variable "name" {
  description = "Name of the bucket, svp-lab-dr-media-<account>-<region>, computed by the root from the account and Region at run time."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-dr-[a-z0-9-]{1,52}$", var.name)) && !endswith(var.name, "-")
    error_message = "name must start with svp-lab-dr-, hold only lowercase letters, digits and hyphens, end with a letter or digit and be at most 63 characters."
  }
}
