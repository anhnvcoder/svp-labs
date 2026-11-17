variable "name" {
  description = "Name of the function, its role and its log group /aws/lambda/<name>: svp-lab-sls-<part>."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-sls-[a-z0-9-]{1,52}$", var.name)) && !endswith(var.name, "-")
    error_message = "name must start with svp-lab-sls-, hold only lowercase letters, digits and hyphens, end with a letter or digit and be at most 64 characters."
  }
}

variable "description" {
  description = "Description of the function."
  type        = string
}

variable "package_path" {
  description = "Path of the zip holding the bootstrap binary, written by the root's archive_file."
  type        = string
}

variable "package_hash" {
  description = "Base64 SHA-256 of the zip (output_base64sha256 of archive_file): a new hash deploys the new code."
  type        = string
}

variable "timeout" {
  description = "Timeout of one invocation, in seconds."
  type        = number

  validation {
    condition     = var.timeout >= 1 && var.timeout <= 900 && floor(var.timeout) == var.timeout
    error_message = "timeout must be a whole number of seconds between 1 and 900."
  }
}

variable "environment" {
  description = "Environment variables of the function."
  type        = map(string)
  default     = {}
}

variable "policy_statements" {
  description = "Allow statements the role gets besides writing its log group. Every action and resource is named: no wildcard, which would widen the role beyond the resources of the lab."
  type = list(object({
    sid       = string
    actions   = list(string)
    resources = list(string)
    condition = optional(map(map(list(string))))
  }))
  default = []

  validation {
    condition = alltrue([
      for s in var.policy_statements : length(s.actions) > 0 && length(s.resources) > 0 &&
      alltrue([for v in concat(s.actions, s.resources) : !strcontains(v, "*")])
    ])
    error_message = "Each statement names at least one action and one resource, none with a wildcard (*)."
  }
}
