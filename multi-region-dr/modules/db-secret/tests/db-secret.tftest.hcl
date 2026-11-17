# Validation rules of the variables, then the secret the lab relies on: one replica in the DR Region, deleted without a
# recovery window, and a value written through the write-only argument. The AWS provider is a mock.

mock_provider "aws" {}

variables {
  name             = "svp-lab-dr-db-master"
  replica_region   = "us-east-1"
  password         = "test-only-not-a-secret"
  password_version = 1
}

run "secret" {
  command = plan

  assert {
    condition     = one(aws_secretsmanager_secret.this.replica[*].region) == "us-east-1"
    error_message = "The secret has one replica, in the DR Region."
  }

  assert {
    condition     = aws_secretsmanager_secret.this.recovery_window_in_days == 0
    error_message = "The destroy of a session deletes the secret at once."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.this.secret_string_wo_version == 1 && aws_secretsmanager_secret_version.this.secret_string == null
    error_message = "The value goes through the write-only argument, never secret_string."
  }
}

run "name_outside_the_lab" {
  command = plan

  variables {
    name = "svp-prd-db"
  }

  expect_failures = [var.name]
}

run "replica_region_outside_the_organization" {
  command = plan

  variables {
    replica_region = "xx-nowhere-1"
  }

  expect_failures = [var.replica_region]
}

run "password_version_zero" {
  command = plan

  variables {
    password_version = 0
  }

  expect_failures = [var.password_version]
}
