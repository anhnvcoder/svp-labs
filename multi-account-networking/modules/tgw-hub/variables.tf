variable "name" {
  description = "Name of the transit gateway and prefix of the names of its route tables (<name>-rt-prd, <name>-rt-nonprd, <name>-rt-egress), e.g. svp-lab-net."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 32 lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "attachments" {
  description = "Transit gateway attachment of each VPC of the lab, keyed egress, shared, stg and prd: the attachment id and the IPv4 CIDR of the VPC. The key decides the route table: egress alone in the egress table, shared and stg in the non-prd table, prd in the prd table."
  type = map(object({
    id   = string
    cidr = string
  }))

  validation {
    condition     = toset(keys(var.attachments)) == toset(["egress", "shared", "stg", "prd"])
    error_message = "attachments must hold exactly the keys egress, shared, stg and prd."
  }

  validation {
    condition     = alltrue([for a in values(var.attachments) : can(cidrnetmask(a.cidr)) && a.cidr != "0.0.0.0/0"])
    error_message = "Each cidr must be an IPv4 range other than 0.0.0.0/0, e.g. 10.64.32.0/20."
  }

  validation {
    condition     = length(distinct([for a in values(var.attachments) : a.cidr])) == length(var.attachments)
    error_message = "Each attachment must have a CIDR of its own."
  }
}
