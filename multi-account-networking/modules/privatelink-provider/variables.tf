variable "name" {
  description = "Name of the load balancer, its target group, the endpoint service and the HTTP unit, e.g. svp-lab-net-svc."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 32 lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "vpc_id" {
  description = "ID of the VPC of the load balancer and its target."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC ID, e.g. vpc-0123456789abcdef0."
  }
}

variable "subnet_id" {
  description = "ID of the one subnet of the load balancer; its zone is the only zone the endpoint service is offered in."
  type        = string

  validation {
    condition     = can(regex("^subnet-[0-9a-f]+$", var.subnet_id))
    error_message = "subnet_id must be a subnet ID, e.g. subnet-0123456789abcdef0."
  }
}

variable "instance_id" {
  description = "ID of the instance that serves HTTP on port 80, behind the load balancer; its security group must admit port 80 from the load balancer's subnet."
  type        = string

  validation {
    condition     = can(regex("^i-[0-9a-f]+$", var.instance_id))
    error_message = "instance_id must be an instance ID, e.g. i-0123456789abcdef0."
  }
}

variable "consumer_account_id" {
  description = "The one account (12 digits) allowed to create endpoints to the service."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.consumer_account_id))
    error_message = "consumer_account_id must be the 12 digits of an AWS account id."
  }
}

variable "accepted_endpoint_ids" {
  description = "Interface endpoints of the consumer, under a key known before apply, whose connection requests are accepted, e.g. { stg = <endpoint ID> }."
  type        = map(string)

  validation {
    condition     = alltrue([for id in values(var.accepted_endpoint_ids) : can(regex("^vpce-[0-9a-f]+$", id))])
    error_message = "Each value of accepted_endpoint_ids must be a VPC endpoint ID."
  }
}
