variable "name" {
  description = "Name of the replication role (svp-lab-dr-media-replication)."
  type        = string

  validation {
    condition     = can(regex("^svp-lab-dr-[a-z0-9-]{1,40}$", var.name))
    error_message = "name must start with svp-lab-dr- and go on with 1 to 40 lowercase letters, digits or hyphens."
  }
}

variable "source_bucket_name" {
  description = "Name of the source bucket in the primary Region (output name of its bucket module), versioning on."
  type        = string

  validation {
    condition     = startswith(var.source_bucket_name, "svp-lab-dr-")
    error_message = "source_bucket_name must be a bucket of the lab, svp-lab-dr-..."
  }
}

variable "destination_bucket_arn" {
  description = "ARN of the destination bucket in the DR Region (output arn of its bucket module), versioning on."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:s3:::svp-lab-dr-[a-z0-9-]+$", var.destination_bucket_arn))
    error_message = "destination_bucket_arn must be the ARN of a bucket of the lab, arn:aws:s3:::svp-lab-dr-..."
  }
}
