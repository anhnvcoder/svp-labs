# Validation rules of the variables, then the shape the lab measures: a Multi-AZ primary with its password through the
# write-only argument only, a read replica of it that carries no password, 5432 from the loader only, and
# nothing left after the destroy. The AWS provider is a mock; plans only.

mock_provider "aws" {}

variables {
  name                     = "svp-lab-ds-rds"
  vpc_id                   = "vpc-0123456789abcdef0"
  subnet_ids               = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
  client_security_group_id = "sg-0aaaaaaaaaaaaaaa1"
  master_password          = "test-only-not-a-secret"
  password_version         = 1
}

run "primary_and_replica" {
  command = plan

  assert {
    condition     = aws_db_instance.primary.engine == "postgres" && aws_db_instance.primary.engine_version == "17" && aws_db_instance.primary.instance_class == "db.t4g.micro"
    error_message = "The primary is PostgreSQL 17 on db.t4g.micro."
  }

  assert {
    condition     = aws_db_instance.primary.multi_az && !aws_db_instance.replica.multi_az
    error_message = "The primary is Multi-AZ, with one standby; the replica is Single-AZ."
  }

  assert {
    condition     = aws_db_instance.replica.replicate_source_db == "svp-lab-ds-rds" && aws_db_instance.replica.identifier == "svp-lab-ds-rds-replica"
    error_message = "The replica names the primary as its source, in the same Region."
  }

  assert {
    condition     = aws_db_instance.primary.password_wo_version == 1 && aws_db_instance.primary.password == null && aws_db_instance.primary.manage_master_user_password == null
    error_message = "The master password goes through password_wo only; RDS manages no second password."
  }

  assert {
    condition     = aws_db_instance.replica.password == null && aws_db_instance.replica.password_wo_version == null && aws_db_instance.replica.manage_master_user_password == null
    error_message = "The replica carries no password of its own: it takes its source's."
  }

  assert {
    condition     = aws_db_instance.primary.storage_encrypted && !aws_db_instance.primary.publicly_accessible && !aws_db_instance.replica.publicly_accessible
    error_message = "Storage is encrypted and no instance is public."
  }

  assert {
    condition     = aws_db_instance.primary.backup_retention_period == 1 && aws_db_instance.replica.backup_retention_period == 0
    error_message = "One day of backups on the primary, the least a read replica needs; none on the replica."
  }

  assert {
    condition     = alltrue([for i in [aws_db_instance.primary, aws_db_instance.replica] : i.delete_automated_backups && i.skip_final_snapshot && !i.deletion_protection])
    error_message = "The destroy leaves no final snapshot nor automated backup."
  }

  assert {
    condition     = alltrue([for i in [aws_db_instance.primary, aws_db_instance.replica] : !i.performance_insights_enabled && i.monitoring_interval == 0])
    error_message = "No Performance Insights nor Enhanced Monitoring: no measure needs them."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.client.referenced_security_group_id == "sg-0aaaaaaaaaaaaaaa1" && aws_vpc_security_group_ingress_rule.client.from_port == 5432 && aws_vpc_security_group_ingress_rule.client.to_port == 5432 && aws_vpc_security_group_ingress_rule.client.cidr_ipv4 == null
    error_message = "Only the loader reaches PostgreSQL, on 5432, by security group."
  }

  assert {
    condition     = aws_security_group.this.name == "svp-lab-ds-rds-db" && length(aws_db_instance.replica.vpc_security_group_ids) == 1 && length(aws_db_instance.primary.vpc_security_group_ids) == 1
    error_message = "The primary and the replica sit in the one group svp-lab-ds-rds-db."
  }
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

run "client_not_a_group" {
  command = plan

  variables {
    client_security_group_id = "10.67.0.0/20"
  }

  expect_failures = [var.client_security_group_id]
}

run "instance_class_not_burstable" {
  command = plan

  variables {
    instance_class = "db.m7g.large"
  }

  expect_failures = [var.instance_class]
}

run "password_version_zero" {
  command = plan

  variables {
    password_version = 0
  }

  expect_failures = [var.password_version]
}

run "master_username_with_uppercase" {
  command = plan

  variables {
    master_username = "SvpAdmin"
  }

  expect_failures = [var.master_username]
}
