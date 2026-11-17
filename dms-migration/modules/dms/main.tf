# DMS of the lab: a private replication instance in the AWS-side VPC, source and target endpoints that read their
# credentials from Secrets Manager through an interface endpoint (the VPC has no route out), and one full load and CDC
# task with validation and logging on, created stopped. Design notes: dms-migration/README.md.

data "aws_region" "current" {}

data "aws_partition" "current" {}

locals {
  region = data.aws_region.current.region
  dms_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dms.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  managed_policy = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role"
}

# DMS looks these two roles up by their fixed names, once per account. A role the account already has is passed as
# not to create, so that the destroy leaves it in place.
resource "aws_iam_role" "vpc" {
  count = var.create_vpc_role ? 1 : 0

  name               = "dms-vpc-role"
  description        = "DMS manages the network interfaces of its replication instances"
  assume_role_policy = local.dms_trust
}

resource "aws_iam_role_policy_attachment" "vpc" {
  count = var.create_vpc_role ? 1 : 0

  role       = aws_iam_role.vpc[0].name
  policy_arn = "${local.managed_policy}/AmazonDMSVPCManagementRole"
}

resource "aws_iam_role" "logs" {
  count = var.create_logs_role ? 1 : 0

  name               = "dms-cloudwatch-logs-role"
  description        = "DMS writes the logs of its replication tasks to CloudWatch Logs"
  assume_role_policy = local.dms_trust
}

resource "aws_iam_role_policy_attachment" "logs" {
  count = var.create_logs_role ? 1 : 0

  role       = aws_iam_role.logs[0].name
  policy_arn = "${local.managed_policy}/AmazonDMSCloudWatchLogsRole"
}

# Created only once dms-vpc-role can act; the destroy removes the group before the role for the same reason.
resource "aws_dms_replication_subnet_group" "this" {
  replication_subnet_group_id          = var.name
  replication_subnet_group_description = "Private subnets of ${var.name}"
  subnet_ids                           = var.subnet_ids

  depends_on = [aws_iam_role_policy_attachment.vpc]
}

resource "aws_security_group" "dms" {
  name        = var.name
  description = "DMS ${var.name}: no inbound, PostgreSQL to source and target, HTTPS to the Secrets Manager endpoint"
  vpc_id      = var.vpc_id

  tags = {
    Name = var.name
  }
}

resource "aws_vpc_security_group_egress_rule" "source" {
  for_each = toset(var.source_cidrs)

  security_group_id = aws_security_group.dms.id
  description       = "PostgreSQL to the on-premises source through the peering"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "target" {
  security_group_id = aws_security_group.dms.id
  description       = "PostgreSQL to the RDS target in this VPC"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = var.target_cidr
}

resource "aws_vpc_security_group_egress_rule" "secrets" {
  security_group_id            = aws_security_group.dms.id
  description                  = "HTTPS to the Secrets Manager interface endpoint"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.endpoint.id
}

resource "aws_security_group" "endpoint" {
  name        = "${var.name}-secretsmanager"
  description = "Secrets Manager interface endpoint of ${var.name}: HTTPS from DMS only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-secretsmanager"
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoint" {
  security_group_id            = aws_security_group.endpoint.id
  description                  = "HTTPS from the DMS replication instance"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.dms.id
}

# One zone, the zone of the replication instance: the instance reads the secrets when it connects, and a second zone
# would double the hourly price for no reader.
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${local.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [var.subnet_ids[0]]
  security_group_ids  = [aws_security_group.endpoint.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.name}-secretsmanager"
  }
}

resource "aws_dms_replication_instance" "this" {
  replication_instance_id     = var.name
  replication_instance_class  = var.instance_class
  allocated_storage           = var.allocated_storage
  engine_version              = var.engine_version
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false
  apply_immediately           = true
  availability_zone           = var.availability_zone
  multi_az                    = false
  publicly_accessible         = false
  network_type                = "IPV4"
  replication_subnet_group_id = aws_dms_replication_subnet_group.this.id
  vpc_security_group_ids      = [aws_security_group.dms.id]

  tags = {
    Name = var.name
  }
}

# The CA bundle of RDS for the Region, which verify-full checks the target's certificate and host name against.
resource "aws_dms_certificate" "rds" {
  certificate_id  = "${var.name}-rds-ca"
  certificate_pem = var.rds_ca_bundle
}

# DMS assumes the role through its regional service principal, as the DMS guide for secrets requires.
resource "aws_iam_role" "secrets" {
  name        = "${var.name}-secrets"
  description = "DMS reads the credentials of the endpoints of ${var.name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dms.${local.region}.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "secrets" {
  name = "read-endpoint-secrets"
  role = aws_iam_role.secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = [var.source_secret_arn, var.target_secret_arn]
    }]
  })
}

locals {
  # The replication instance reaches Secrets Manager only through the interface endpoint of its VPC.
  secrets_override = "secretsManagerEndpointOverride=${aws_vpc_endpoint.secretsmanager.dns_entry[0].dns_name}"
}

# The on-premises server has a self-signed certificate, so require encrypts without verifying it. DDL capture stays
# off: the schema is created on both sides before the task, and DMS then leaves no trigger or table on the source.
resource "aws_dms_endpoint" "source" {
  endpoint_id                     = "${var.name}-source"
  endpoint_type                   = "source"
  engine_name                     = "postgres"
  database_name                   = var.database_name
  ssl_mode                        = "require"
  secrets_manager_arn             = var.source_secret_arn
  secrets_manager_access_role_arn = aws_iam_role.secrets.arn
  extra_connection_attributes     = local.secrets_override

  postgres_settings {
    capture_ddls = false
    plugin_name  = "test-decoding"
  }

  depends_on = [aws_iam_role_policy.secrets]
}

resource "aws_dms_endpoint" "target" {
  endpoint_id                     = "${var.name}-target"
  endpoint_type                   = "target"
  engine_name                     = "postgres"
  database_name                   = var.database_name
  ssl_mode                        = "verify-full"
  certificate_arn                 = aws_dms_certificate.rds.certificate_arn
  secrets_manager_arn             = var.target_secret_arn
  secrets_manager_access_role_arn = aws_iam_role.secrets.arn
  extra_connection_attributes     = local.secrets_override

  depends_on = [aws_iam_role_policy.secrets]
}

# DMS writes the task logs into dms-tasks-<replication instance id>; created here, the group has a retention and goes
# with the destroy.
resource "aws_cloudwatch_log_group" "task" {
  name              = "dms-tasks-${var.name}"
  retention_in_days = 1
}

# Created stopped: the session script starts it once the schema exists on both sides. The target tables are created
# beforehand, so the full load truncates them instead of letting DMS create bare tables.
resource "aws_dms_replication_task" "this" {
  replication_task_id      = var.name
  migration_type           = "full-load-and-cdc"
  replication_instance_arn = aws_dms_replication_instance.this.replication_instance_arn
  source_endpoint_arn      = aws_dms_endpoint.source.endpoint_arn
  target_endpoint_arn      = aws_dms_endpoint.target.endpoint_arn
  start_replication_task   = false

  table_mappings = jsonencode({
    rules = [for i, t in var.tables : {
      rule-type      = "selection"
      rule-id        = tostring(i + 1)
      rule-name      = t
      object-locator = { schema-name = "public", table-name = t }
      rule-action    = "include"
    }]
  })

  replication_task_settings = jsonencode({
    FullLoadSettings   = { TargetTablePrepMode = "TRUNCATE_BEFORE_LOAD" }
    ValidationSettings = { EnableValidation = true }
    Logging = {
      EnableLogging = true
      LogComponents = [for c in ["SOURCE_UNLOAD", "SOURCE_CAPTURE", "TARGET_LOAD", "TARGET_APPLY"] : {
        Id       = c
        Severity = "LOGGER_SEVERITY_DEFAULT"
      }]
    }
  })

  depends_on = [aws_cloudwatch_log_group.task, aws_iam_role_policy_attachment.logs]
}
