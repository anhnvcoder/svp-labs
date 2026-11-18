# Aurora PostgreSQL of the data-scaling lab: one writer and one reader in the two zones of the data subnets, so a
# failover moves the writer to the other zone. Storage is the cluster volume Aurora keeps in three zones of the Region.
# Design notes: data-scaling/README.md.

# The newest minor of the major: Aurora takes no major version alone, and RDS Proxy follows the cluster's version.
data "aws_rds_engine_version" "this" {
  engine  = "aurora-postgresql"
  version = var.engine_major_version
  latest  = true
}

# The zone of each data subnet, to pin the writer to the first and the reader to the second.
data "aws_subnet" "data" {
  count = 2

  id = var.subnet_ids[count.index]
}

resource "aws_db_subnet_group" "this" {
  name        = var.name
  description = "Database subnets of ${var.name}"
  subnet_ids  = var.subnet_ids

  tags = {
    Name = var.name
  }
}

# No egress rule: Terraform removes the allow-all rule AWS puts on a new group, and the cluster opens no connection.
resource "aws_security_group" "this" {
  name        = "${var.name}-db"
  description = "Aurora PostgreSQL ${var.name}, 5432 from the loader and the proxy only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-db"
  }
}

resource "aws_vpc_security_group_ingress_rule" "client" {
  for_each = var.client_security_group_ids

  security_group_id            = aws_security_group.this.id
  description                  = "PostgreSQL from the ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = each.value
}

# AWS-0079: storage encrypted under the AWS managed key aws/rds, not a customer managed key: the rows are throwaway and
# a key of its own would add a KMS bill and a deletion window to a lab destroyed within the session. One day of
# backups, the shortest Aurora keeps, deleted with the cluster; no final snapshot.
#trivy:ignore:AWS-0079
resource "aws_rds_cluster" "this" {
  cluster_identifier = var.name
  engine             = "aurora-postgresql"
  engine_version     = data.aws_rds_engine_version.this.version_actual

  database_name              = var.db_name
  master_username            = var.master_username
  master_password_wo         = var.master_password
  master_password_wo_version = var.password_version

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  storage_encrypted      = true

  backup_retention_period  = 1
  delete_automated_backups = true
  skip_final_snapshot      = true
  deletion_protection      = false
  copy_tags_to_snapshot    = true
  apply_immediately        = true

  allow_major_version_upgrade = false

  tags = {
    Name = var.name
  }
}

# The first instance of a cluster becomes its writer, so the reader waits for it. Both carry the same promotion tier:
# a failover may pick either. The bundle of this CA is in the global bundle the loader verifies the server against.
resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.name}-1"
  cluster_identifier = aws_rds_cluster.this.cluster_identifier
  engine             = aws_rds_cluster.this.engine
  engine_version     = aws_rds_cluster.this.engine_version
  instance_class     = var.instance_class
  availability_zone  = data.aws_subnet.data[0].availability_zone
  promotion_tier     = 1
  ca_cert_identifier = "rds-ca-rsa2048-g1"

  db_subnet_group_name         = aws_db_subnet_group.this.name
  publicly_accessible          = false
  performance_insights_enabled = false
  monitoring_interval          = 0
  auto_minor_version_upgrade   = true
  apply_immediately            = true

  tags = {
    Name = "${var.name}-1"
  }
}

resource "aws_rds_cluster_instance" "reader" {
  identifier         = "${var.name}-2"
  cluster_identifier = aws_rds_cluster.this.cluster_identifier
  engine             = aws_rds_cluster.this.engine
  engine_version     = aws_rds_cluster.this.engine_version
  instance_class     = var.instance_class
  availability_zone  = data.aws_subnet.data[1].availability_zone
  promotion_tier     = 1
  ca_cert_identifier = "rds-ca-rsa2048-g1"

  db_subnet_group_name         = aws_db_subnet_group.this.name
  publicly_accessible          = false
  performance_insights_enabled = false
  monitoring_interval          = 0
  auto_minor_version_upgrade   = true
  apply_immediately            = true

  tags = {
    Name = "${var.name}-2"
  }

  depends_on = [aws_rds_cluster_instance.writer]
}
