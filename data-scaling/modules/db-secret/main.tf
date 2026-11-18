# The master credentials of the postgres part, the one source of the password: Aurora and RDS read it back from this
# secret, and RDS Proxy logs in to Aurora with it. The value comes in through write-only arguments, so it is in neither
# the plan nor the state. Design notes: data-scaling/README.md.

# Forced deletion and the AWS managed key aws/secretsmanager: the lab destroys everything at the end of the session.
resource "aws_secretsmanager_secret" "this" {
  name                    = var.name
  description             = "Master user of the Aurora and RDS PostgreSQL of the data-scaling lab, read by RDS Proxy"
  recovery_window_in_days = 0
}

# The JSON keys RDS Proxy reads from a secret of database credentials.
resource "aws_secretsmanager_secret_version" "this" {
  secret_id = aws_secretsmanager_secret.this.id
  secret_string_wo = jsonencode({
    username = var.username
    password = var.password
  })
  secret_string_wo_version = var.password_version
}
