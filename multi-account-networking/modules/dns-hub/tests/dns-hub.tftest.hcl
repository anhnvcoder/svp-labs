# The central DNS with the records of the lab: zones, records, the zone in the Profile and the authorization of the
# stg VPC; then one plan per validation rule. The AWS provider is a mock: nothing reaches an account.

mock_provider "aws" {}

variables {
  name   = "svp-lab-net"
  vpc_id = "vpc-0123456789abcdef0"
  records = {
    net    = { egress-probe = "10.64.2.10", shared-probe = "10.64.16.10" }
    nonprd = { shared-probe = "10.64.16.10" }
  }
  nonprd_vpc_ids = { stg = "vpc-0aaaaaaaaaaaaaaa1" }
}

run "dns" {
  command = plan

  assert {
    condition = (aws_route53_zone.this["net"].name == "net.svp.example" &&
    aws_route53_zone.this["nonprd"].name == "nonprd.svp.example")
    error_message = "The zones must be net.svp.example and nonprd.svp.example."
  }

  assert {
    condition     = alltrue([for z in aws_route53_zone.this : length(z.vpc) == 1 && one(z.vpc).vpc_id == "vpc-0123456789abcdef0"])
    error_message = "Both zones must be private, created with the given VPC of this account."
  }

  assert {
    condition = (aws_route53_record.this["shared-probe.net"].name == "shared-probe.net.svp.example" &&
      aws_route53_record.this["shared-probe.net"].records == toset(["10.64.16.10"]) &&
    aws_route53_record.this["shared-probe.nonprd"].name == "shared-probe.nonprd.svp.example")
    error_message = "Each record must be <host>.<zone name> with its address."
  }

  assert {
    condition     = length(aws_route53_record.this) == 3 && alltrue([for r in aws_route53_record.this : r.type == "A"])
    error_message = "Expected three A records."
  }

  assert {
    condition     = keys(aws_route53_vpc_association_authorization.nonprd) == ["stg"]
    error_message = "Only the stg VPC may associate itself with the zone nonprd."
  }

  assert {
    condition = (aws_route53profiles_profile.this.name == "svp-lab-net" &&
    aws_route53profiles_resource_association.net.name == "svp-lab-net-net")
    error_message = "The Profile svp-lab-net must hold the zone net."
  }
}

run "records_unknown_zone" {
  command = plan

  variables {
    records = { onprem = { router = "192.168.0.10" } }
  }

  expect_failures = [var.records]
}

run "records_not_an_address" {
  command = plan

  variables {
    records = { net = { shared-probe = "10.64.16" } }
  }

  expect_failures = [var.records]
}

run "nonprd_vpc_ids_invalid" {
  command = plan

  variables {
    nonprd_vpc_ids = { stg = "subnet-0123" }
  }

  expect_failures = [var.nonprd_vpc_ids]
}

run "vpc_id_invalid" {
  command = plan

  variables {
    vpc_id = "vpc-XYZ"
  }

  expect_failures = [var.vpc_id]
}
