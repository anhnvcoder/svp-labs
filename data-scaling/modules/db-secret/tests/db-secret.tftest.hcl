# Validation rules of the variables, then the secret the part relies on: deleted without a recovery window, and a value
# written through the write-only argument only. The AWS provider is a mock.

mock_provider "aws" {}

variables {
  name             = "svp-lab-ds-pg-master"
  username         = "svp_admin"
  password         = "test-only-not-a-secret"
  password_version = 1
}

run "secret" {
  command = plan

  assert {
    condition     = aws_secretsmanager_secret.this.name == "svp-lab-ds-pg-master" && aws_secretsmanager_secret.this.recovery_window_in_days == 0
    error_message = "The destroy of a session deletes the secret at once."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.this.secret_string_wo_version == 1 && aws_secretsmanager_secret_version.this.secret_string == null
    error_message = "The value goes through the write-only argument, never secret_string."
  }

  assert {
    condition     = aws_secretsmanager_secret.this.kms_key_id == null && length(aws_secretsmanager_secret.this.replica) == 0
    error_message = "The secret uses the AWS managed key and stays in its Region."
  }
}

run "name_outside_the_lab" {
  command = plan

  variables {
    name = "svp-prd-db"
  }

  expect_failures = [var.name]
}

run "username_with_hyphen" {
  command = plan

  variables {
    username = "svp-admin"
  }

  expect_failures = [var.username]
}

run "password_version_zero" {
  command = plan

  variables {
    password_version = 0
  }

  expect_failures = [var.password_version]
}
