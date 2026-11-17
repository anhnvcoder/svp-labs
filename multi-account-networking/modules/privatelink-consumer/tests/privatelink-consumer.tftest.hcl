# The consumer side of PrivateLink in stg: one assertion per decision, then one plan per validation rule. The AWS
# provider is a mock: nothing reaches an account.

mock_provider "aws" {}

variables {
  name         = "svp-lab-net-svc-stg"
  vpc_id       = "vpc-0123456789abcdef0"
  vpc_cidr     = "10.64.32.0/20"
  subnet_id    = "subnet-0123456789abcdef0"
  service_name = "com.amazonaws.vpce.ap-southeast-1.vpce-svc-0123456789abcdef0"
}

run "consumer" {
  command = plan

  assert {
    condition = (aws_vpc_endpoint.this.vpc_endpoint_type == "Interface" && aws_vpc_endpoint.this.private_dns_enabled == false &&
    aws_vpc_endpoint.this.service_name == "com.amazonaws.vpce.ap-southeast-1.vpce-svc-0123456789abcdef0")
    error_message = "One interface endpoint to the service, without a private DNS name."
  }

  assert {
    condition     = aws_vpc_endpoint.this.subnet_ids == toset(["subnet-0123456789abcdef0"])
    error_message = "The endpoint must have one interface, in the given subnet."
  }

  assert {
    condition = (aws_vpc_security_group_ingress_rule.this.cidr_ipv4 == "10.64.32.0/20" &&
      aws_vpc_security_group_ingress_rule.this.ip_protocol == "tcp" && aws_vpc_security_group_ingress_rule.this.from_port == 80 &&
    aws_vpc_security_group_ingress_rule.this.to_port == 80)
    error_message = "The endpoint may take TCP 80 from its own VPC only."
  }
}

run "service_not_endpoint_service" {
  command = plan

  variables {
    service_name = "com.amazonaws.ap-southeast-1.s3"
  }

  expect_failures = [var.service_name]
}

run "vpc_cidr_everything" {
  command = plan

  variables {
    vpc_cidr = "0.0.0.0/0"
  }

  expect_failures = [var.vpc_cidr]
}

run "port_invalid" {
  command = plan

  variables {
    port = 70000
  }

  expect_failures = [var.port]
}

run "name_uppercase" {
  command = plan

  variables {
    name = "Svp-lab-net-svc-stg"
  }

  expect_failures = [var.name]
}
