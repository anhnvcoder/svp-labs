# Consumer side of PrivateLink: an interface endpoint in a spoke VPC to an endpoint service of another account. The
# packets never cross the transit gateway, so it joins two VPCs that the hub keeps apart.
resource "aws_security_group" "this" {
  name        = var.name
  description = "Interface endpoint ${var.name}: TCP ${var.port} from its own VPC"
  vpc_id      = var.vpc_id

  tags = {
    Name = var.name
  }
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  security_group_id = aws_security_group.this.id
  description       = "TCP ${var.port} from the VPC of the endpoint"
  ip_protocol       = "tcp"
  from_port         = var.port
  to_port           = var.port
  cidr_ipv4         = var.vpc_cidr
}

# No private DNS name: the service has none, since verifying one needs a public domain the lab does not own.
resource "aws_vpc_endpoint" "this" {
  vpc_id              = var.vpc_id
  service_name        = var.service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [var.subnet_id]
  security_group_ids  = [aws_security_group.this.id]
  private_dns_enabled = false

  tags = {
    Name = var.name
  }
}
