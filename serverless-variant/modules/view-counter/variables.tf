variable "queue_arn" {
  description = "ARN of the view queue the counter reads."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:sqs:[a-z0-9-]+:[0-9]{12}:svp-lab-sls-[a-z0-9-]+$", var.queue_arn))
    error_message = "queue_arn must be the ARN of an SQS queue of the lab (svp-lab-sls-...)."
  }
}

variable "function_name" {
  description = "Name of the counter function; its role must already read the queue and write the table."
  type        = string

  validation {
    condition     = startswith(var.function_name, "svp-lab-sls-")
    error_message = "function_name must name a function of the lab (svp-lab-sls-...)."
  }
}
