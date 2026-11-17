# One RDS for PostgreSQL instance of the lab in one Region: the primary, or, with replicate_source_db, its cross-Region
# read replica. The DR call also replicates the primary's automated backups into its Region, the backup and restore
# path the lab compares with the replica. Design notes: multi-region-dr/README.md.

locals {
  replica = var.replicate_source_db != null
}

resource "aws_db_subnet_group" "this" {
  name        = var.name
  description = "Database subnets of ${var.name}"
  subnet_ids  = var.subnet_ids

  tags = {
    Name = var.name
  }
}

# A fixed name: the drill script finds the group by it to cut the bastion off. No egress rule: Terraform removes the
# allow-all rule AWS puts on a new group, and the instance opens no connection itself.
resource "aws_security_group" "this" {
  name        = "${var.name}-db"
  description = "PostgreSQL ${var.name}, 5432 from the bastion of its Region only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-db"
  }
}

resource "aws_vpc_security_group_ingress_rule" "client" {
  security_group_id            = aws_security_group.this.id
  description                  = "PostgreSQL from the bastion"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = var.client_security_group_id
}

# Storage under the aws/rds key of the Region: the key of the primary Region by default, the one given in kms_key_arn
# for a replica, which RDS requires for an encrypted replica in another Region. PostgreSQL 15 and later refuse plain
# connections by default (rds.force_ssl = 1), so the default parameter group is enough.
resource "aws_db_instance" "this" {
  identifier          = var.name
  replicate_source_db = var.replicate_source_db
  engine              = local.replica ? null : "postgres"
  engine_version      = local.replica ? null : var.engine_major_version
  instance_class      = var.instance_class

  storage_type      = "gp3"
  allocated_storage = local.replica ? null : 20
  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  # The bundle of this CA is in the global bundle the bastion verifies the server against.
  ca_cert_identifier = "rds-ca-rsa2048-g1"

  db_name             = local.replica ? null : var.db_name
  username            = local.replica ? null : var.master_username
  password_wo         = local.replica ? null : var.master_password
  password_wo_version = local.replica ? null : var.password_version

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = false

  # The primary needs automated backups to feed a replica; a replica starts without them, and the promotion of the
  # drill sets them. Deleting them with the instance leaves nothing billed after the destroy.
  backup_retention_period  = local.replica ? 0 : var.backup_retention_period
  delete_automated_backups = true
  skip_final_snapshot      = true
  deletion_protection      = false
  copy_tags_to_snapshot    = true
  apply_immediately        = true

  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false

  tags = {
    Name = var.name
  }
}

# Lives in the destination Region, as RDS requires; destroying it stops the replication but keeps the replicated
# backups until their retention ends, so the lab deletes them after the destroy.
resource "aws_db_instance_automated_backups_replication" "this" {
  count = var.replicate_backups_from != null ? 1 : 0

  source_db_instance_arn = var.replicate_backups_from
  kms_key_id             = var.kms_key_arn
  retention_period       = var.replicated_backup_retention_days
}
