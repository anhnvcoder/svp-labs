output "name" {
  description = "Name of the secret; the loader's scripts read it at run time."
  value       = aws_secretsmanager_secret.this.name
}

output "arn" {
  description = "ARN of the secret: the loader's role and the proxy's role may read it."
  value       = aws_secretsmanager_secret.this.arn
}

output "version_id" {
  description = "Version holding the value written by the last password_version, the one the root reads back for the databases."
  value       = aws_secretsmanager_secret_version.this.version_id
}
