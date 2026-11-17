# The master password of the lab's PostgreSQL, kept in the primary Region and replicated by Secrets Manager into the DR
# Region, so that the DR side reads its own copy when the primary Region is gone. The value comes in through write-only
# arguments: it is in neither the plan nor the state. Design notes: multi-region-dr/README.md.

# Forced deletion and AWS managed keys: the lab destroys everything at the end of the session, and Secrets Manager
# encrypts both copies with the aws/secretsmanager key of their Region by default.
resource "aws_secretsmanager_secret" "this" {
  name                    = var.name
  description             = "Master password of the PostgreSQL instances of the multi-region-dr lab"
  recovery_window_in_days = 0

  replica {
    region = var.replica_region
  }
}

resource "aws_secretsmanager_secret_version" "this" {
  secret_id                = aws_secretsmanager_secret.this.id
  secret_string_wo         = var.password
  secret_string_wo_version = var.password_version
}
