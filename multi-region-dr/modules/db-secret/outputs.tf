output "name" {
  description = "Name of the secret, the same in both Regions."
  value       = aws_secretsmanager_secret.this.name
}

output "arn" {
  description = "ARN of the secret in the primary Region."
  value       = aws_secretsmanager_secret.this.arn
}

# The ARN of a replica is the ARN of the primary secret with the replica's Region in it.
output "replica_arn" {
  description = "ARN of the replica of the secret in replica_region."
  value       = replace(aws_secretsmanager_secret.this.arn, ":${split(":", aws_secretsmanager_secret.this.arn)[3]}:", ":${var.replica_region}:")
}
