# The machine that runs the lab's measurement script in one Region: the SSM agent opens the session outward, so the
# instance takes no inbound connection and holds no SSH key. It sits in a public subnet with a public address instead of
# behind a NAT gateway, which would cost more than the instance. Design notes: multi-region-dr/README.md.

data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_partition" "current" {}

resource "aws_iam_role" "this" {
  name        = var.name
  description = "Bastion ${var.name} of the multi-region-dr lab: SSM agent and the database password of its Region"

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

# The secret of the instance's own Region only: the DR side reads its replica, never the lost Region.
resource "aws_iam_role_policy" "secret" {
  name = "read-db-password"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = var.secret_arn
    }]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = var.name
  role = aws_iam_role.this.name
}

resource "aws_security_group" "this" {
  name        = var.name
  description = "Bastion ${var.name}: no inbound, HTTPS out, PostgreSQL inside the VPC"
  vpc_id      = var.vpc_id

  tags = {
    Name = var.name
  }
}

# AWS-0104: HTTPS to any address. The SSM agent, Secrets Manager, the package repositories and the RDS certificate
# bundle are public endpoints without one prefix list; interface endpoints would cost more per hour than the bastion.
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "HTTPS to AWS APIs, package repositories and the RDS certificate bundle"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "postgres" {
  security_group_id = aws_security_group.this.id
  description       = "PostgreSQL inside the VPC"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = var.vpc_cidr
}

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

  # Written out so that the cost table of the lab counts a known size.
  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  tags = {
    Name = var.name
  }
}
