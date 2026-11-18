# RDS Proxy in front of the Aurora cluster of the data-scaling lab: clients open short connections to the proxy, which
# keeps a pool of connections to the writer and logs in with the part's secret. TLS is required from the client; the
# proxy presents a certificate of ACM, not of the RDS CA. Design notes: data-scaling/README.md.

locals {
  # The secret's Region, the one Secrets Manager decrypts it in.
  region = split(":", var.secret_arn)[3]
}

# The AWS managed key of Secrets Manager, which encrypts the part's secret.
data "aws_kms_key" "secretsmanager" {
  key_id = "alias/aws/secretsmanager"
}

resource "aws_iam_role" "this" {
  name        = var.name
  description = "RDS Proxy ${var.name} of the data-scaling lab: reads the master user secret of its target"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# The policy RDS Proxy documents: read the secret, and decrypt with its key only through Secrets Manager.
resource "aws_iam_role_policy" "secret" {
  name = "read-secret"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = var.secret_arn
      },
      {
        Effect    = "Allow"
        Action    = "kms:Decrypt"
        Resource  = data.aws_kms_key.secretsmanager.arn
        Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${local.region}.amazonaws.com" } }
      },
    ]
  })
}

# Rules as separate resources only: Terraform removes the allow-all egress rule AWS puts on a new group, so the proxy
# reaches the cluster's group on 5432 and nothing else.
resource "aws_security_group" "this" {
  name        = var.name
  description = "RDS Proxy ${var.name}: 5432 from the loader, 5432 to the Aurora cluster only"
  vpc_id      = var.vpc_id

  tags = {
    Name = var.name
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

resource "aws_vpc_security_group_egress_rule" "target" {
  security_group_id            = aws_security_group.this.id
  description                  = "PostgreSQL to the Aurora cluster"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = var.target_security_group_id
}

resource "aws_db_proxy" "this" {
  name                   = var.name
  engine_family          = "POSTGRESQL"
  require_tls            = true
  role_arn               = aws_iam_role.this.arn
  vpc_subnet_ids         = var.subnet_ids
  vpc_security_group_ids = [aws_security_group.this.id]
  debug_logging          = false

  auth {
    auth_scheme               = "SECRETS"
    secret_arn                = var.secret_arn
    iam_auth                  = "DISABLED"
    client_password_auth_type = "POSTGRES_SCRAM_SHA_256"
    description               = "Master user of ${var.cluster_identifier}"
  }

  tags = {
    Name = var.name
  }

  # The role must hold its policy before the proxy first reads the secret.
  depends_on = [aws_iam_role_policy.secret]
}

resource "aws_db_proxy_default_target_group" "this" {
  db_proxy_name = aws_db_proxy.this.name
}

resource "aws_db_proxy_target" "this" {
  db_proxy_name         = aws_db_proxy.this.name
  target_group_name     = aws_db_proxy_default_target_group.this.name
  db_cluster_identifier = var.cluster_identifier
}
