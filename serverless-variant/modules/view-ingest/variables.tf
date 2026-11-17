variable "visibility_timeout_seconds" {
  description = "Visibility timeout of the main queue: at least six times the counter's timeout plus its batching window, so a batch is not delivered again while Lambda still works on it or retries it after throttling."
  type        = number

  validation {
    condition     = var.visibility_timeout_seconds >= 0 && var.visibility_timeout_seconds <= 43200 && floor(var.visibility_timeout_seconds) == var.visibility_timeout_seconds
    error_message = "visibility_timeout_seconds must be a whole number of seconds between 0 and 43200 (12 hours, the SQS maximum)."
  }
}
