# Validation rules of the variables, then the two shapes of the module: the primary (engine, user, write-only password,
# backups) and the cross-Region replica (source by ARN, key of its Region, no user, plus the replicated backups). The
# AWS provider is a mock; plans only.

mock_provider "aws" {}

variables {
  name                     = "svp-lab-dr-primary"
  vpc_id                   = "vpc-0123456789abcdef0"
  subnet_ids               = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
  client_security_group_id = "sg-0123456789abcdef0"
  master_password          = "test-only-not-a-secret"
  password_version         = 1
}

run "primary" {
  command = plan

  assert {
    condition     = aws_db_instance.this.engine == "postgres" && aws_db_instance.this.engine_version == "17" && aws_db_instance.this.instance_class == "db.t4g.micro"
    error_message = "The primary is PostgreSQL 17 on db.t4g.micro."
  }

  assert {
    condition     = aws_db_instance.this.password_wo_version == 1 && aws_db_instance.this.password == null && aws_db_instance.this.username == "svp_admin"
    error_message = "The master password goes through password_wo only."
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted && !aws_db_instance.this.publicly_accessible && !aws_db_instance.this.multi_az
    error_message = "The primary is encrypted, private and Single-AZ."
  }

  assert {
    condition     = aws_db_instance.this.backup_retention_period == 1 && aws_db_instance.this.delete_automated_backups && aws_db_instance.this.skip_final_snapshot && !aws_db_instance.this.deletion_protection
    error_message = "The primary keeps one day of backups for its replica and leaves nothing behind when destroyed."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.client.referenced_security_group_id == "sg-0123456789abcdef0" && aws_vpc_security_group_ingress_rule.client.from_port == 5432
    error_message = "Only the bastion reaches PostgreSQL."
  }

  assert {
    condition     = aws_security_group.this.name == "svp-lab-dr-primary-db" && length(aws_db_instance_automated_backups_replication.this) == 0
    error_message = "The group has the name the drill looks up, and the primary replicates no backup."
  }
}

run "replica" {
  command = plan

  variables {
    name                   = "svp-lab-dr-replica"
    replicate_source_db    = "arn:aws:rds:ap-southeast-1:000000000000:db:svp-lab-dr-primary"
    replicate_backups      = true
    replicate_backups_from = "arn:aws:rds:ap-southeast-1:000000000000:db:svp-lab-dr-primary"
    kms_key_arn            = "arn:aws:kms:us-east-1:000000000000:key/00000000-0000-0000-0000-000000000000"
    password_version       = null
  }

  assert {
    condition     = aws_db_instance.this.replicate_source_db == var.replicate_source_db && aws_db_instance.this.kms_key_id == var.kms_key_arn
    error_message = "The replica names its source by ARN and uses the key of its own Region."
  }

  assert {
    condition     = aws_db_instance.this.password_wo_version == null
    error_message = "A replica takes its password from its source."
  }

  assert {
    condition     = aws_db_instance.this.backup_retention_period == 0
    error_message = "The replica starts without backups; the promotion sets them."
  }

  assert {
    condition     = aws_db_instance_automated_backups_replication.this[0].source_db_instance_arn == var.replicate_backups_from && aws_db_instance_automated_backups_replication.this[0].retention_period == 1
    error_message = "The DR call replicates the primary's backups for one day, with the key of its Region."
  }
}

run "backups_off_replicates_nothing" {
  command = plan

  variables {
    replicate_backups      = false
    replicate_backups_from = "arn:aws:rds:ap-southeast-1:000000000000:db:svp-lab-dr-primary"
  }

  assert {
    condition     = length(aws_db_instance_automated_backups_replication.this) == 0
    error_message = "With replicate_backups off nothing is replicated, whatever replicate_backups_from holds."
  }
}

run "backups_on_without_arn" {
  command = plan

  variables {
    replicate_backups = true
    kms_key_arn       = "arn:aws:kms:us-east-1:000000000000:key/00000000-0000-0000-0000-000000000000"
  }

  expect_failures = [var.replicate_backups_from]
}

run "replica_without_key" {
  command = plan

  variables {
    name                = "svp-lab-dr-replica"
    replicate_source_db = "arn:aws:rds:ap-southeast-1:000000000000:db:svp-lab-dr-primary"
  }

  expect_failures = [var.kms_key_arn]
}

run "replicated_backups_without_key" {
  command = plan

  variables {
    replicate_backups      = true
    replicate_backups_from = "arn:aws:rds:ap-southeast-1:000000000000:db:svp-lab-dr-primary"
  }

  expect_failures = [var.kms_key_arn]
}

run "replicate_source_db_by_identifier" {
  command = plan

  variables {
    replicate_source_db = "svp-lab-dr-primary"
    kms_key_arn         = "arn:aws:kms:us-east-1:000000000000:key/00000000-0000-0000-0000-000000000000"
  }

  expect_failures = [var.replicate_source_db]
}

run "primary_without_password_version" {
  command = plan

  variables {
    password_version = null
  }

  expect_failures = [var.password_version]
}

run "name_outside_the_lab" {
  command = plan

  variables {
    name = "svp-prd"
  }

  expect_failures = [var.name]
}

run "subnet_ids_one_zone" {
  command = plan

  variables {
    subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1"]
  }

  expect_failures = [var.subnet_ids]
}

run "instance_class_not_burstable" {
  command = plan

  variables {
    instance_class = "db.m7g.large"
  }

  expect_failures = [var.instance_class]
}

run "backup_retention_zero" {
  command = plan

  variables {
    backup_retention_period = 0
  }

  expect_failures = [var.backup_retention_period]
}

run "replicated_backup_retention_too_long" {
  command = plan

  variables {
    replicated_backup_retention_days = 36
  }

  expect_failures = [var.replicated_backup_retention_days]
}

run "db_name_with_hyphen" {
  command = plan

  variables {
    db_name = "svp-lab"
  }

  expect_failures = [var.db_name]
}

run "master_username_with_uppercase" {
  command = plan

  variables {
    master_username = "SvpAdmin"
  }

  expect_failures = [var.master_username]
}
