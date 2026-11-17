# The credentials of one DMS endpoint in the JSON form DMS reads: username, password, host and port. The value goes in
# through a write-only argument, written only when password_version changes, so neither the plan nor the state holds
# it; a new host is written by raising the version too. Design notes: dms-migration/README.md.

# Deleted without a recovery window and encrypted with the aws/secretsmanager key: the lab is destroyed at the end of
# the session, and DMS and the clients read the secret without a KMS grant of their own.
resource "aws_secretsmanager_secret" "this" {
  name                    = var.name
  description             = var.description
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "this" {
  secret_id = aws_secretsmanager_secret.this.id
  secret_string_wo = jsonencode({
    username = var.username
    password = var.password
    host     = var.host
    port     = tostring(var.port)
  })
  secret_string_wo_version = var.password_version
}
