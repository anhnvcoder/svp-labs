variable "name" {
  description = "Name of the proxy (svp-lab-ds-proxy), also the name of its IAM role and its security group."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-ds-[a-z]{1,20}$", var.name))
    error_message = "name must be svp-lab-ds- followed by 1 to 20 lowercase letters."
  }
}

variable "vpc_id" {
  description = "VPC of the proxy (output vpc_id of the network module)."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC id such as vpc-0abc..."
  }
}

variable "subnet_ids" {
  description = "The two data subnets, in two availability zones (output data_subnet_ids of the network module): RDS Proxy needs subnets in at least two zones."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) == 2 && alltrue([for s in var.subnet_ids : can(regex("^subnet-[0-9a-f]+$", s))])
    error_message = "subnet_ids must hold exactly two subnet ids, in two availability zones."
  }
}

variable "client_security_group_id" {
  description = "Security group of the loader, the only client let in on 5432."
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]+$", var.client_security_group_id))
    error_message = "client_security_group_id must be a security group id such as sg-0abc..."
  }
}

variable "target_security_group_id" {
  description = "Security group of the Aurora cluster, the only destination of the proxy's traffic (5432)."
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]+$", var.target_security_group_id))
    error_message = "target_security_group_id must be a security group id such as sg-0abc..."
  }
}

variable "cluster_identifier" {
  description = "Identifier of the Aurora cluster the proxy fronts (svp-lab-ds-aurora)."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-ds-[a-z]{1,20}$", var.cluster_identifier))
    error_message = "cluster_identifier must be a cluster of the lab, svp-lab-ds- followed by 1 to 20 lowercase letters."
  }
}

variable "secret_arn" {
  description = "ARN of the part's secret, JSON {\"username\", \"password\"} of the cluster's master user; the proxy's role may read it and no other."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$", var.secret_arn))
    error_message = "secret_arn must be the ARN of a Secrets Manager secret."
  }
}
