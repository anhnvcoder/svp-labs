# The on-premises stand-in: self-managed PostgreSQL on EC2, which is also the application host that writes the load and
# runs the cutover. The SSM agent opens the session outward, so the instance takes no SSH and lets in only DMS on 5432.
# The DMS user's password sits in an SSM parameter that the boot script reads. Design notes: dms-migration/README.md.

data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  # Built from the name rather than read from the parameter, so the policy is known before the parameter exists.
  parameter_arn = join(":", [
    "arn", data.aws_partition.current.partition, "ssm", data.aws_region.current.region,
    data.aws_caller_identity.current.account_id, "parameter${var.password_parameter_name}",
  ])
}

# Holds no host, so a new instance boots against the same parameter. Standard tier and the aws/ssm key: no charge.
resource "aws_ssm_parameter" "password" {
  name             = var.password_parameter_name
  description      = "Password of the DMS user of the on-premises PostgreSQL of the dms-migration lab"
  type             = "SecureString"
  value_wo         = var.password
  value_wo_version = var.password_version
}

resource "aws_iam_role" "this" {
  name        = var.name
  description = "On-premises stand-in of the dms-migration lab: SSM agent, its DMS user password, the cutover"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# The decrypt grant names the parameter through the encryption context Parameter Store sends to KMS.
resource "aws_iam_role_policy" "password" {
  name = "read-dms-user-password"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = local.parameter_arn
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService"                      = "ssm.${data.aws_region.current.region}.amazonaws.com"
            "kms:EncryptionContext:PARAMETER_ARN" = local.parameter_arn
          }
        }
      },
    ]
  })
}

# The cutover reads the target's credentials, waits for the validation of the one task and stops it.
resource "aws_iam_role_policy" "cutover" {
  name = "cutover"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = var.target_secret_arn
      },
      {
        Effect   = "Allow"
        Action   = ["dms:DescribeTableStatistics", "dms:StopReplicationTask"]
        Resource = var.task_arn
      },
    ]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = var.name
  role = aws_iam_role.this.name
}

resource "aws_security_group" "this" {
  name        = var.name
  description = "On-premises PostgreSQL ${var.name}: 5432 from DMS only, HTTPS out, PostgreSQL to the AWS side"
  vpc_id      = var.vpc_id

  tags = {
    Name = var.name
  }
}

resource "aws_vpc_security_group_ingress_rule" "dms" {
  for_each = toset(var.dms_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "PostgreSQL from the DMS subnets through the peering"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = each.value
}

# AWS-0104: HTTPS to any address. The SSM agent, Systems Manager, Secrets Manager, DMS, the package repositories and the
# RDS certificate bundle are public endpoints without one prefix list; interface endpoints cost more than the address.
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "HTTPS to AWS APIs, package repositories and the RDS certificate bundle"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "target" {
  security_group_id = aws_security_group.this.id
  description       = "PostgreSQL to the AWS side through the peering"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = var.target_cidr
}

# The boot script reads the parameter, so the instance starts only once the parameter and the grant exist.
resource "aws_instance" "this" {
  ami                         = data.aws_ssm_parameter.ami.insecure_value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = true
  user_data                   = var.user_data
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Written out so that the cost table of the lab counts a known size; the data, the WAL a slot holds included.
  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  # The instance holds the source database and the slot: a newer AMI between two applies must not replace it.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name = var.name
  }

  depends_on = [aws_ssm_parameter.password, aws_iam_role_policy.password]
}
