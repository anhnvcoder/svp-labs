variable "name" {
  description = "Name of the resource share, e.g. svp-lab-net-tgw."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 32 lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "resource_arns" {
  description = "ARN of each resource to share, under a key known before apply (the ARNs are not), e.g. { tgw = <transit gateway ARN> }."
  type        = map(string)

  validation {
    condition     = length(var.resource_arns) > 0
    error_message = "resource_arns must name at least one resource."
  }
}

variable "principals" {
  description = "Account IDs of the organization that receive the resources (12 digits each). Organizations or OUs are not accepted: the lab shares with named accounts only."
  type        = list(string)

  validation {
    condition     = length(var.principals) > 0 && alltrue([for p in var.principals : can(regex("^[0-9]{12}$", p))])
    error_message = "principals must hold at least one account ID of 12 digits, and nothing else."
  }

  validation {
    condition     = length(distinct(var.principals)) == length(var.principals)
    error_message = "principals must not repeat an account."
  }
}
