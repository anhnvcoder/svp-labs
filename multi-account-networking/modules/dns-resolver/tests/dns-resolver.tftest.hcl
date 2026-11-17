# Hybrid DNS with the lab's ranges: one assertion per decision, then one plan per validation rule. The AWS provider is
# a mock: nothing reaches an account. Resource IDs exist only after apply and are not compared.

mock_provider "aws" {}

variables {
  name                 = "svp-lab-net-resolver"
  vpc_id               = "vpc-0123456789abcdef0"
  availability_zone_id = "apse1-az1"
  subnet_cidr          = "10.64.18.0/28"
  transit_gateway_id   = "tgw-0123456789abcdef0"
  site_cidr            = "192.168.0.0/20"
  site_dns_ip          = "192.168.0.10"
  site_zone            = "onprem.svp.example"
  profile_id           = "rp-0123456789abcdef"
}

run "resolver" {
  command = plan

  assert {
    condition = (aws_route53_resolver_endpoint.this["inbound"].direction == "INBOUND" &&
    aws_route53_resolver_endpoint.this["outbound"].direction == "OUTBOUND")
    error_message = "One inbound and one outbound endpoint."
  }

  assert {
    condition = (toset([for a in aws_route53_resolver_endpoint.this["inbound"].ip_address : a.ip]) == toset(["10.64.18.4", "10.64.18.5"]) &&
    toset([for a in aws_route53_resolver_endpoint.this["outbound"].ip_address : a.ip]) == toset(["10.64.18.6", "10.64.18.7"]))
    error_message = "Each endpoint must have its two fixed addresses, the minimum Resolver accepts."
  }

  assert {
    condition     = output.inbound_ips == ["10.64.18.4", "10.64.18.5"]
    error_message = "The site's server must be given the inbound addresses."
  }

  assert {
    condition = alltrue([for r in aws_vpc_security_group_ingress_rule.inbound :
    r.cidr_ipv4 == "192.168.0.0/20" && r.from_port == 53 && r.to_port == 53 && contains(["udp", "tcp"], r.ip_protocol)])
    error_message = "The inbound endpoint may take DNS from the site only."
  }

  assert {
    condition = alltrue([for r in aws_vpc_security_group_egress_rule.outbound :
    r.cidr_ipv4 == "192.168.0.10/32" && r.from_port == 53 && r.to_port == 53 && contains(["udp", "tcp"], r.ip_protocol)])
    error_message = "The outbound endpoint may send DNS to the site's server only."
  }

  assert {
    condition = (aws_route53_resolver_rule.site.rule_type == "FORWARD" && aws_route53_resolver_rule.site.domain_name == "onprem.svp.example" &&
    [for t in aws_route53_resolver_rule.site.target_ip : "${t.ip}:${t.port}"] == ["192.168.0.10:53"])
    error_message = "The rule must forward the site's zone to the site's server alone."
  }

  assert {
    condition     = aws_route53profiles_resource_association.site.profile_id == "rp-0123456789abcdef"
    error_message = "The rule must reach the spokes through the lab's Route 53 Profile."
  }

  assert {
    condition = (aws_route.site.destination_cidr_block == "192.168.0.0/20" && aws_route.site.transit_gateway_id == "tgw-0123456789abcdef0" &&
    aws_subnet.this.cidr_block == "10.64.18.0/28")
    error_message = "The endpoints' subnet must route only the site's range, through the transit gateway."
  }
}

run "subnet_not_28" {
  command = plan

  variables {
    subnet_cidr = "10.64.18.0/24"
  }

  expect_failures = [var.subnet_cidr]
}

run "site_everything" {
  command = plan

  variables {
    site_cidr = "0.0.0.0/0"
  }

  expect_failures = [var.site_cidr]
}

run "dns_ip_invalid" {
  command = plan

  variables {
    site_dns_ip = "192.168.0.0/20"
  }

  expect_failures = [var.site_dns_ip]
}

run "zone_uppercase" {
  command = plan

  variables {
    site_zone = "OnPrem.svp.example"
  }

  expect_failures = [var.site_zone]
}

run "profile_invalid" {
  command = plan

  variables {
    profile_id = "vpc-0123456789abcdef0"
  }

  expect_failures = [var.profile_id]
}
