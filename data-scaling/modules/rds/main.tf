# RDS for PostgreSQL of the data-scaling lab: a Multi-AZ primary (one synchronous standby in another zone, not
# readable) and a read replica in the same Region, the shape the lab compares with Aurora's writer and reader.
# Design notes: data-scaling/README.md.

resource "aws_db_subnet_group" "this" {
  name        = var.name
  description = "Database subnets of ${var.name}"
  subnet_ids  = var.subnet_ids

  tags = {
    Name = var.name
  }
}

# One group for the primary and the replica. No egress rule: Terraform removes the allow-all rule AWS puts on a new
# group, and the instances open no connection outside RDS replication.
resource "aws_security_group" "this" {
  name        = "${var.name}-db"
  description = "RDS PostgreSQL ${var.name} and its replica, 5432 from the loader only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-db"
  }
}

resource "aws_vpc_security_group_ingress_rule" "client" {
  security_group_id            = aws_security_group.this.id
  description                  = "PostgreSQL from the loader"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = var.client_security_group_id
}

# Storage under the AWS managed key aws/rds. One day of backups, the least that lets RDS make a read replica, deleted
# with the instance; no final snapshot. PostgreSQL 15 and later refuse plain connections by default (rds.force_ssl).
resource "aws_db_instance" "primary" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_major_version
  instance_class = var.instance_class

  storage_type      = "gp3"
  allocated_storage = 20
  storage_encrypted = true

  # The bundle of this CA is in the global bundle the loader verifies the server against.
  ca_cert_identifier = "rds-ca-rsa2048-g1"

  db_name             = var.db_name
  username            = var.master_username
  password_wo         = var.master_password
  password_wo_version = var.password_version

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = true

  backup_retention_period  = 1
  delete_automated_backups = true
  skip_final_snapshot      = true
  deletion_protection      = false
  copy_tags_to_snapshot    = true
  apply_immediately        = true

  performance_insights_enabled = false
  monitoring_interval          = 0
  auto_minor_version_upgrade   = true
  allow_major_version_upgrade  = false

  tags = {
    Name = var.name
  }
}

# Same Region, so the source goes by identifier, and the replica takes its source's engine, user, password and
# database. Being the dependant, it is destroyed before the primary. Single-AZ and no backups of its own.
resource "aws_db_instance" "replica" {
  identifier          = "${var.name}-replica"
  replicate_source_db = aws_db_instance.primary.identifier
  instance_class      = var.instance_class

  storage_type      = "gp3"
  storage_encrypted = true

  ca_cert_identifier = "rds-ca-rsa2048-g1"

  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period  = 0
  delete_automated_backups = true
  skip_final_snapshot      = true
  deletion_protection      = false
  apply_immediately        = true

  performance_insights_enabled = false
  monitoring_interval          = 0
  auto_minor_version_upgrade   = true

  tags = {
    Name = "${var.name}-replica"
  }
}
