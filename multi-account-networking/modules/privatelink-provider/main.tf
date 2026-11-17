# Provider side of PrivateLink: an internal Network Load Balancer in front of a small HTTP service on a test instance,
# published as an endpoint service that one other account may connect to, each connection accepted by name. Design
# notes: multi-account-networking/README.md.
locals {
  port = 80

  # A static page served by Python from the image, as an unprivileged user that may bind the port.
  http_command = join("; ", [
    "set -e",
    "mkdir -p /srv/${var.name}",
    "echo ${var.name} > /srv/${var.name}/index.html",
    "systemctl stop ${var.name}-http 2>/dev/null || true",
    join(" ", [
      "systemd-run --unit=${var.name}-http -p DynamicUser=yes -p AmbientCapabilities=CAP_NET_BIND_SERVICE",
      "/usr/bin/python3 -m http.server ${local.port} --directory /srv/${var.name}",
    ]),
  ])
}

# Runs once through the SSM agent, which the instance already has: the instance is not replaced and its user data
# stays as it is.
resource "aws_ssm_association" "http" {
  association_name = "${var.name}-http"
  name             = "AWS-RunShellScript"

  parameters = {
    commands = local.http_command
  }

  targets {
    key    = "InstanceIds"
    values = [var.instance_id]
  }
}

# No security group on the load balancer: the target's own group, which admits the lab's range, is the one filter.
resource "aws_lb" "this" {
  name               = var.name
  internal           = true
  load_balancer_type = "network"
  subnets            = [var.subnet_id]

  tags = {
    Name = var.name
  }
}

resource "aws_lb_target_group" "this" {
  name        = var.name
  port        = local.port
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    protocol = "TCP"
  }

  tags = {
    Name = var.name
  }
}

resource "aws_lb_target_group_attachment" "this" {
  target_group_arn = aws_lb_target_group.this.arn
  target_id        = var.instance_id
  port             = local.port
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = local.port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# Two gates: only the consumer account may ask, and each endpoint it creates waits until the accepter below names it.
# A role of that account with ec2:CreateVpcEndpoint could otherwise connect any VPC of it.
resource "aws_vpc_endpoint_service" "this" {
  acceptance_required        = true
  network_load_balancer_arns = [aws_lb.this.arn]

  tags = {
    Name = var.name
  }
}

resource "aws_vpc_endpoint_service_allowed_principal" "consumer" {
  vpc_endpoint_service_id = aws_vpc_endpoint_service.this.id
  principal_arn           = "arn:aws:iam::${var.consumer_account_id}:root"
}

resource "aws_vpc_endpoint_connection_accepter" "this" {
  for_each = var.accepted_endpoint_ids

  vpc_endpoint_service_id = aws_vpc_endpoint_service.this.id
  vpc_endpoint_id         = each.value
}
