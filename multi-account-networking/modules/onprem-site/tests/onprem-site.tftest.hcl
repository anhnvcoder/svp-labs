# The simulated site with the lab's ranges: one assertion per protection, then one plan per validation rule. The AWS
# provider is a mock: nothing reaches an account; the region and the AMI parameter return the values below, so the
# rendered boot script of the router is known at plan. Resource IDs exist only after apply and are not compared.

mock_provider "aws" {
  mock_data "aws_ssm_parameter" {
    defaults = {
      insecure_value = "ami-0123456789abcdef0"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }
}

variables {
  name                 = "svp-lab-net-onprem"
  cidr                 = "192.168.0.0/20"
  lab_cidr             = "10.64.0.0/16"
  availability_zone_id = "apse1-az1"
  public_ip            = "198.51.100.10"
  eip_allocation_id    = "eipalloc-0123456789abcdef0"
  tunnels = [
    { outside_ip = "203.0.113.1", cgw_inside_ip = "169.254.10.2" },
    { outside_ip = "203.0.113.2", cgw_inside_ip = "169.254.11.2" },
  ]
  preshared_key_arn    = "arn:aws:secretsmanager:ap-southeast-1:555555555555:secret:s2svpn-example"
  zone_name            = "onprem.svp.example"
  forward_zones        = ["net.svp.example", "nonprd.svp.example"]
  inbound_resolver_ips = ["10.64.16.20", "10.64.16.21"]
}

run "site" {
  command = plan

  assert {
    condition = (aws_subnet.this["edge"].cidr_block == "192.168.0.0/24" && aws_subnet.this["lan"].cidr_block == "192.168.1.0/24" &&
    aws_network_interface.router.private_ips == toset(["192.168.0.10"]) && aws_instance.host.private_ip == "192.168.1.10")
    error_message = "The router must sit at 192.168.0.10 in the edge /24 and the host at 192.168.1.10 in the lan /24."
  }

  assert {
    condition     = aws_network_interface.router.source_dest_check == false
    error_message = "The router forwards packets that are not its own: its source/destination check must be off."
  }

  assert {
    condition     = aws_eip_association.router.allocation_id == "eipalloc-0123456789abcdef0"
    error_message = "The Elastic IP of the customer gateway must be the router's public address."
  }

  assert {
    condition = alltrue([for r in aws_vpc_security_group_ingress_rule.router_ike :
    r.ip_protocol == "udp" && contains([500, 4500], r.from_port) && r.from_port == r.to_port && contains(["203.0.113.1/32", "203.0.113.2/32"], r.cidr_ipv4)])
    error_message = "The router may take only UDP 500 and 4500, from the two tunnel addresses alone."
  }

  assert {
    condition = (length(aws_vpc_security_group_ingress_rule.router_ike) == 4 &&
    aws_vpc_security_group_ingress_rule.router_site.cidr_ipv4 == "192.168.0.0/20")
    error_message = "The router's only other ingress is the site's own range: nothing else from the internet, no SSH."
  }

  assert {
    condition = alltrue([for r in aws_vpc_security_group_ingress_rule.host :
    r.cidr_ipv4 == "10.64.0.0/16" && (r.ip_protocol == "icmp" || (r.ip_protocol == "tcp" && r.from_port == 80 && r.to_port == 80))])
    error_message = "The host may take only ping and TCP 80 from the lab: no SSH, nothing from the internet."
  }

  assert {
    condition = alltrue([for i in [aws_instance.router, aws_instance.host] :
      i.metadata_options[0].http_tokens == "required" && i.metadata_options[0].http_put_response_hop_limit == 1 &&
    i.root_block_device[0].encrypted == true && i.instance_type == "t4g.nano"])
    error_message = "Both instances: t4g.nano, IMDSv2 with hop limit 1, encrypted root volume."
  }

  assert {
    condition = (strcontains(aws_instance.router.user_data, "get-secret-value --secret-id 'arn:aws:secretsmanager:ap-southeast-1:555555555555:secret:s2svpn-example'") &&
    jsondecode(aws_iam_role_policy.router_key.policy).Statement[0].Resource == var.preshared_key_arn)
    error_message = "The router must read the keys at boot from the secret, the only secret its role may read."
  }

  assert {
    condition = (jsondecode(aws_iam_role_policy.router_key.policy).Statement[0].Action == "secretsmanager:GetSecretValue" &&
    length(jsondecode(aws_iam_role_policy.router_key.policy).Statement) == 1)
    error_message = "The role may only read that secret's value."
  }

  assert {
    condition = (strcontains(aws_instance.router.user_data, "right=203.0.113.1") && strcontains(aws_instance.router.user_data, "right=203.0.113.2") &&
      strcontains(aws_instance.router.user_data, "leftid=198.51.100.10") && strcontains(aws_instance.router.user_data, "leftsubnet=192.168.0.0/20") &&
    strcontains(aws_instance.router.user_data, "rightsubnet=10.64.0.0/16"))
    error_message = "Both tunnels must run from the Elastic IP and carry only the site's range to the lab's."
  }

  assert {
    condition = (strcontains(aws_instance.router.user_data, "allow-recursion { 127.0.0.1; 192.168.0.0/20; };") &&
    strcontains(aws_instance.router.user_data, "forwarders { 10.64.16.20; 10.64.16.21; };"))
    error_message = "The site's DNS must recurse for the site only and forward the lab's zones to the inbound endpoint."
  }

  assert {
    condition     = aws_route.lab.destination_cidr_block == "10.64.0.0/16" && aws_route.lab.gateway_id == null
    error_message = "The host's subnet must send the lab through the router."
  }

  assert {
    condition     = aws_subnet.this["edge"].map_public_ip_on_launch == false && aws_subnet.this["lan"].map_public_ip_on_launch == false
    error_message = "No subnet may hand out public addresses on its own."
  }
}

run "cidr_not_20" {
  command = plan

  variables {
    cidr = "192.168.0.0/16"
  }

  expect_failures = [var.cidr]
}

run "eip_allocation_invalid" {
  command = plan

  variables {
    eip_allocation_id = "198.51.100.10"
  }

  expect_failures = [var.eip_allocation_id]
}

run "one_tunnel" {
  command = plan

  variables {
    tunnels = [{ outside_ip = "203.0.113.1", cgw_inside_ip = "169.254.10.2" }]
  }

  expect_failures = [var.tunnels]
}

run "tunnel_inside_not_link_local" {
  command = plan

  variables {
    tunnels = [
      { outside_ip = "203.0.113.1", cgw_inside_ip = "10.0.0.2" },
      { outside_ip = "203.0.113.2", cgw_inside_ip = "169.254.11.2" },
    ]
  }

  expect_failures = [var.tunnels]
}

run "key_arn_not_secret" {
  command = plan

  variables {
    preshared_key_arn = "arn:aws:ssm:ap-southeast-1:555555555555:parameter/vpn"
  }

  expect_failures = [var.preshared_key_arn]
}

run "one_inbound_ip" {
  command = plan

  variables {
    inbound_resolver_ips = ["10.64.16.20"]
  }

  expect_failures = [var.inbound_resolver_ips]
}

run "name_uppercase" {
  command = plan

  variables {
    name = "Svp-lab-net-onprem"
  }

  expect_failures = [var.name]
}
