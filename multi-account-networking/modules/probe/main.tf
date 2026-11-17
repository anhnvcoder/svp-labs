# A test instance that the learner reaches through Session Manager to measure packet paths. The SSM agent opens the
# session outward, so the instance takes no inbound connection from outside the lab, holds no SSH key and has no
# public address; it reaches the Systems Manager endpoints through the central egress like any other traffic.
locals {
  # Graviton, the smallest size: the instance only sends pings, a few TCP connections and DNS queries.
  instance_type = "t4g.nano"
  # Amazon Linux 2023 arm64 from the public SSM parameter that AWS keeps current; its image includes the SSM agent.
  ami_parameter = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"

  # Ping and TCP 80 from any VPC of the lab: what the session commands and Reachability Analyzer test. Nothing listens
  # on 80; a refused connection proves the path as well as an answer would.
  ingress = {
    icmp = { ip_protocol = "icmp", from_port = -1, to_port = -1 }
    http = { ip_protocol = "tcp", from_port = 80, to_port = 80 }
  }
}

data "aws_ssm_parameter" "ami" {
  name = local.ami_parameter
}

resource "aws_iam_role" "this" {
  name        = var.name
  description = "SSM agent of the test instance ${var.name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Only the AWS managed policy of the SSM agent: the probe needs no other AWS API.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name = var.name
  role = aws_iam_role.this.name
}

# With no egress block, Terraform strips the default allow-all egress rule and the rules below are the only exits.
# Security groups do not filter DNS queries to the VPC resolver.
resource "aws_security_group" "this" {
  name        = var.name
  description = "Test instance ${var.name}: ping and TCP 80 from the lab, HTTPS out"
  vpc_id      = var.vpc_id

  tags = {
    Name = var.name
  }
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = local.ingress

  security_group_id = aws_security_group.this.id
  description       = "${each.key} from the VPCs of the lab"
  ip_protocol       = each.value.ip_protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  cidr_ipv4         = var.lab_cidr
}

resource "aws_vpc_security_group_egress_rule" "lab" {
  security_group_id = aws_security_group.this.id
  description       = "Any traffic to the VPCs of the lab: the probes test each other"
  ip_protocol       = "-1"
  cidr_ipv4         = var.lab_cidr
}

# AWS-0104: HTTPS to any address. The agent reaches the public endpoints of Systems Manager through the central
# egress, and the probe tests the internet path over HTTPS; AWS publishes no prefix list for those endpoints.
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "HTTPS to Systems Manager and to the internet test site"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_instance" "this" {
  ami                         = data.aws_ssm_parameter.ami.insecure_value
  instance_type               = local.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = false

  # IMDSv2 only, one hop, as the organization's declarative policy requires: a launch with IMDSv1 is refused.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Encrypted explicitly: the network account does not get the main path's default EBS encryption.
  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = var.name
  }
}
