# A simulated on-premises site: a VPC outside the transit gateway whose router instance runs IPsec to the AWS VPN and
# the site's DNS server, and a host behind the router. Design notes: multi-account-networking/README.md.
locals {
  # The router's subnet routes only to the internet gateway; the host's subnet sends the lab through the router.
  subnets = {
    edge = cidrsubnet(var.cidr, 4, 0)
    lan  = cidrsubnet(var.cidr, 4, 1)
  }

  router_ip = cidrhost(local.subnets.edge, 10)
  host_ip   = cidrhost(local.subnets.lan, 10)

  # Same image and size as the probes of the lab: Graviton, the smallest size, Amazon Linux 2023 arm64.
  instance_type = "t4g.nano"
  ami_parameter = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"

  # IKE and NAT traversal from each AWS tunnel endpoint. The router sits behind the 1:1 NAT of its Elastic IP, so
  # IPsec runs inside UDP 4500 and no ESP rule is needed.
  ike_ports = { ike = 500, natt = 4500 }
  ike_rules = merge([
    for i, t in var.tunnels : { for k, p in local.ike_ports : "tunnel${i + 1}-${k}" => { ip = t.outside_ip, port = p } }
  ]...)

  router_user_data = templatefile("${path.module}/templates/router.sh.tftpl", {
    region            = data.aws_region.current.region
    preshared_key_arn = var.preshared_key_arn
    public_ip         = var.public_ip
    router_ip         = local.router_ip
    host_ip           = local.host_ip
    onprem_cidr       = var.cidr
    lab_cidr          = var.lab_cidr
    vpc_dns           = cidrhost(var.cidr, 2)
    tunnels           = var.tunnels
    zone_name         = var.zone_name
    forward_zones     = var.forward_zones
    inbound_ips       = var.inbound_resolver_ips
  })
}

data "aws_region" "current" {}

data "aws_ssm_parameter" "ami" {
  name = local.ami_parameter
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.name
  }
}

# Emptied of rules: a resource left on the default group gets no traffic in or out.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name}-default"
  }
}

resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id               = aws_vpc.this.id
  cidr_block           = each.value
  availability_zone_id = var.availability_zone_id

  # Public addresses are given per instance: the router's Elastic IP, the host's own for Session Manager.
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name}-${each.key}"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = var.name
  }
}

resource "aws_route_table" "this" {
  for_each = local.subnets

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name}-${each.key}"
  }
}

resource "aws_route_table_association" "this" {
  for_each = local.subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.this[each.key].id
}

resource "aws_route" "internet" {
  for_each = local.subnets

  route_table_id         = aws_route_table.this[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

# The host reaches the lab through the router, as a LAN reaches a remote site through its VPN device.
resource "aws_route" "lab" {
  route_table_id         = aws_route_table.this["lan"].id
  destination_cidr_block = var.lab_cidr
  network_interface_id   = aws_network_interface.router.id
}

resource "aws_security_group" "router" {
  name        = "${var.name}-router"
  description = "VPN router of the simulated site: IKE from the AWS tunnels, the site's own traffic"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name}-router"
  }
}

resource "aws_vpc_security_group_ingress_rule" "router_ike" {
  for_each = local.ike_rules

  security_group_id = aws_security_group.router.id
  description       = "IKE and NAT traversal from AWS ${each.key}"
  ip_protocol       = "udp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = "${each.value.ip}/32"
}

resource "aws_vpc_security_group_egress_rule" "router_ike" {
  for_each = local.ike_rules

  security_group_id = aws_security_group.router.id
  description       = "IKE and NAT traversal to AWS ${each.key}"
  ip_protocol       = "udp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = "${each.value.ip}/32"
}

# Packets the host sends to the lab, and DNS queries to the router, arrive here before the router forwards them.
resource "aws_vpc_security_group_ingress_rule" "router_site" {
  security_group_id = aws_security_group.router.id
  description       = "Any traffic from the site: DNS and packets to forward to the lab"
  ip_protocol       = "-1"
  cidr_ipv4         = var.cidr
}

resource "aws_vpc_security_group_egress_rule" "router_site" {
  security_group_id = aws_security_group.router.id
  description       = "Any traffic to the site: DNS answers and packets from the lab"
  ip_protocol       = "-1"
  cidr_ipv4         = var.cidr
}

# AWS-0104: HTTPS to any address. Packages come from the Amazon Linux repositories, and the SSM agent and the key
# lookup reach public AWS endpoints; AWS publishes no prefix list for them.
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "router_https" {
  security_group_id = aws_security_group.router.id
  description       = "HTTPS to the package repositories, Systems Manager and Secrets Manager"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# A fixed address, which the host's route, the DNS zone and the Resolver rule of the lab point to. A router forwards
# packets that are not its own, so the source/destination check is off.
resource "aws_network_interface" "router" {
  subnet_id         = aws_subnet.this["edge"].id
  private_ips       = [local.router_ip]
  security_groups   = [aws_security_group.router.id]
  source_dest_check = false

  tags = {
    Name = "${var.name}-router"
  }
}

# The customer gateway's address, allocated with the VPN connection before the router exists.
resource "aws_eip_association" "router" {
  allocation_id        = var.eip_allocation_id
  network_interface_id = aws_network_interface.router.id

  # The association fails while the VPC has no internet gateway attached, and nothing else orders the two.
  depends_on = [aws_internet_gateway.this]
}

resource "aws_iam_role" "router" {
  name        = "${var.name}-router"
  description = "SSM agent and pre-shared key lookup of the VPN router ${var.name}-router"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "router_ssm" {
  role       = aws_iam_role.router.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# The one secret of the VPN connection, read once at boot; the keys never pass through Terraform or the user data.
resource "aws_iam_role_policy" "router_key" {
  name = "read-vpn-key"
  role = aws_iam_role.router.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = var.preshared_key_arn
    }]
  })
}

resource "aws_iam_instance_profile" "router" {
  name = "${var.name}-router"
  role = aws_iam_role.router.name
}

resource "aws_instance" "router" {
  ami                  = data.aws_ssm_parameter.ami.insecure_value
  instance_type        = local.instance_type
  iam_instance_profile = aws_iam_instance_profile.router.name

  # The interface carries the Elastic IP before launch: the boot script installs packages over the internet.
  primary_network_interface {
    network_interface_id = aws_network_interface.router.id
  }

  user_data                   = local.router_user_data
  user_data_replace_on_change = true

  # IMDSv2 only, one hop, as the organization's declarative policy requires.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.name}-router"
  }

  depends_on = [aws_eip_association.router, aws_iam_role_policy.router_key, aws_route.internet]
}

resource "aws_security_group" "host" {
  name        = "${var.name}-host"
  description = "Host of the simulated site: ping and TCP 80 from the lab, DNS to the router, HTTPS out"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name}-host"
  }
}

resource "aws_vpc_security_group_ingress_rule" "host" {
  for_each = {
    icmp = { ip_protocol = "icmp", from_port = -1, to_port = -1 }
    http = { ip_protocol = "tcp", from_port = 80, to_port = 80 }
  }

  security_group_id = aws_security_group.host.id
  description       = "${each.key} from the VPCs of the lab"
  ip_protocol       = each.value.ip_protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  cidr_ipv4         = var.lab_cidr
}

resource "aws_vpc_security_group_egress_rule" "host_lab" {
  security_group_id = aws_security_group.host.id
  description       = "Any traffic to the VPCs of the lab, through the router"
  ip_protocol       = "-1"
  cidr_ipv4         = var.lab_cidr
}

resource "aws_vpc_security_group_egress_rule" "host_dns" {
  for_each = toset(["udp", "tcp"])

  security_group_id = aws_security_group.host.id
  description       = "DNS over ${each.key} to the site's DNS server on the router"
  ip_protocol       = each.key
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "${local.router_ip}/32"
}

# AWS-0104: HTTPS to any address, for the package repositories and the SSM agent, as on the router.
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "host_https" {
  security_group_id = aws_security_group.host.id
  description       = "HTTPS to the package repositories and Systems Manager"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_iam_role" "host" {
  name        = "${var.name}-host"
  description = "SSM agent of the host ${var.name}-host"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "host_ssm" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "host" {
  name = "${var.name}-host"
  role = aws_iam_role.host.name
}

# A public address of its own instead of a NAT: the host keeps its Session Manager path when the router is down.
resource "aws_instance" "host" {
  ami                         = data.aws_ssm_parameter.ami.insecure_value
  instance_type               = local.instance_type
  subnet_id                   = aws_subnet.this["lan"].id
  private_ip                  = local.host_ip
  vpc_security_group_ids      = [aws_security_group.host.id]
  iam_instance_profile        = aws_iam_instance_profile.host.name
  associate_public_ip_address = true

  # dig, to ask the site's DNS server by address.
  user_data = "#!/bin/bash\ndnf -y install bind-utils\n"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.name}-host"
  }

  depends_on = [aws_route.internet]
}
