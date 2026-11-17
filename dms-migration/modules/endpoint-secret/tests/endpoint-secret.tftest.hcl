# Validation rules of the variables, then the secret DMS reads: deleted without a recovery window and written through
# the write-only argument only. The AWS provider is a mock.

mock_provider "aws" {}

variables {
  name             = "svp-lab-dms-source"
  description      = "svp_engagement on the on-premises stand-in, user svp_dms"
  username         = "svp_dms"
  password         = "test-only-not-a-secret"
  host             = "192.168.16.10"
  password_version = 1
}

run "secret" {
  command = plan

  assert {
    condition     = aws_secretsmanager_secret.this.recovery_window_in_days == 0
    error_message = "The destroy of a session deletes the secret at once."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.this.secret_string_wo_version == 1 && aws_secretsmanager_secret_version.this.secret_string == null
    error_message = "The value goes through the write-only argument, never secret_string."
  }
}

run "password_version_zero" {
  command = plan

  variables {
    password_version = 0
  }

  expect_failures = [var.password_version]
}

run "port_out_of_range" {
  command = plan

  variables {
    port = 70000
  }

  expect_failures = [var.port]
}

run "username_with_uppercase" {
  command = plan

  variables {
    username = "SvpDms"
  }

  expect_failures = [var.username]
}

run "name_outside_the_lab" {
  command = plan

  variables {
    name = "svp-prd-db"
  }

  expect_failures = [var.name]
}
