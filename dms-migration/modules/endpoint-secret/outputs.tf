# A reader that names the secret by this output also waits for its first value.
output "arn" {
  description = "ARN of the secret; the DMS endpoint and the access role of DMS name it."
  value       = aws_secretsmanager_secret.this.arn
  depends_on  = [aws_secretsmanager_secret_version.this]
}

output "name" {
  description = "Name of the secret. The value is never an output."
  value       = aws_secretsmanager_secret.this.name
}
