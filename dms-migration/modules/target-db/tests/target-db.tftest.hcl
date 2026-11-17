# Validation rules of the variables, then the target the lab relies on: PostgreSQL 17 on db.t4g.micro, private,
# Single-AZ in the given zone, backups off, a write-only master password, and 5432 open to DMS and the on-premises
# application only. The AWS provider is a mock.

mock_provider "aws" {}

variables {
  name                  = "svp-lab-dms-target"
  vpc_id                = "vpc-0123456789abcdef0"
  subnet_ids            = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
  availability_zone     = "ap-southeast-1a"
  dms_security_group_id = "sg-0123456789abcdef0"
  client_cidrs          = ["192.168.16.0/24"]
  master_password       = "test-only-not-a-secret"
  password_version      = 1
}

run "target" {
  command = plan

  assert {
    condition     = aws_db_instance.this.engine == "postgres" && aws_db_instance.this.engine_version == "17" && aws_db_instance.this.instance_class == "db.t4g.micro"
    error_message = "The target is PostgreSQL 17 on db.t4g.micro."
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted && !aws_db_instance.this.publicly_accessible && !aws_db_instance.this.multi_az && aws_db_instance.this.availability_zone == "ap-southeast-1a"
    error_message = "The target is encrypted, private and Single-AZ in the zone of DMS and the source."
  }

  assert {
    condition     = aws_db_instance.this.password_wo_version == 1 && aws_db_instance.this.password == null && aws_db_instance.this.manage_master_user_password == null
    error_message = "The master password goes through password_wo only."
  }

  assert {
    condition     = aws_db_instance.this.backup_retention_period == 0 && aws_db_instance.this.skip_final_snapshot && !aws_db_instance.this.deletion_protection
    error_message = "Backups stay off until the cutover and the destroy leaves nothing behind."
  }

  assert {
    condition     = aws_db_instance.this.ca_cert_identifier == "rds-ca-rsa2048-g1" && aws_db_instance.this.db_name == "svp_engagement"
    error_message = "The server certificate comes from the CA the clients verify, and the database is svp_engagement."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.dms.referenced_security_group_id == "sg-0123456789abcdef0" && aws_vpc_security_group_ingress_rule.dms.from_port == 5432
    error_message = "DMS reaches PostgreSQL by its security group."
  }

  assert {
    condition     = [for r in aws_vpc_security_group_ingress_rule.client : r.cidr_ipv4] == ["192.168.16.0/24"]
    error_message = "The on-premises application subnet reaches PostgreSQL, nothing wider."
  }
}

run "client_cidrs_open_to_all" {
  command = plan

  variables {
    client_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.client_cidrs]
}

run "availability_zone_given_a_region" {
  command = plan

  variables {
    availability_zone = "ap-southeast-1"
  }

  expect_failures = [var.availability_zone]
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

run "password_version_zero" {
  command = plan

  variables {
    password_version = 0
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
