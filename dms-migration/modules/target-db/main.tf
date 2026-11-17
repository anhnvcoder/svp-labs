# The migration target: RDS for PostgreSQL, private, Single-AZ, in the availability zone of the DMS instance and the
# source so that no byte crosses zones. Backups stay off until the cutover, as the DMS best practices advise for a
# target. Design notes: dms-migration/README.md.

resource "aws_db_subnet_group" "this" {
  name        = var.name
  description = "Subnets of ${var.name}"
  subnet_ids  = var.subnet_ids

  tags = {
    Name = var.name
  }
}

# No egress rule: Terraform removes the allow-all rule AWS puts on a new group, and the instance opens no connection.
resource "aws_security_group" "this" {
  name        = var.name
  description = "PostgreSQL ${var.name}: 5432 from DMS and from the on-premises application subnet"
  vpc_id      = var.vpc_id

  tags = {
    Name = var.name
  }
}

resource "aws_vpc_security_group_ingress_rule" "dms" {
  security_group_id            = aws_security_group.this.id
  description                  = "PostgreSQL from the DMS replication instance"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = var.dms_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "client" {
  for_each = toset(var.client_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "PostgreSQL from the on-premises application through the peering"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = each.value
}

# PostgreSQL 15 and later on RDS refuse plain connections by default (rds.force_ssl = 1), so the default parameter group
# is enough for verify-full clients.
resource "aws_db_instance" "this" {
  identifier        = var.name
  engine            = "postgres"
  engine_version    = var.engine_major_version
  instance_class    = var.instance_class
  availability_zone = var.availability_zone

  storage_type      = "gp3"
  allocated_storage = 20
  storage_encrypted = true

  # The CA in the regional bundle that DMS and the clients verify the server against.
  ca_cert_identifier = "rds-ca-rsa2048-g1"

  db_name             = var.db_name
  username            = var.master_username
  password_wo         = var.master_password
  password_wo_version = var.password_version

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period  = 0
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
