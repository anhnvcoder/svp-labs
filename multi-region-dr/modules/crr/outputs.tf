output "role_arn" {
  description = "ARN of the role S3 assumes to replicate."
  value       = aws_iam_role.this.arn
}
