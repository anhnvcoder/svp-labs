# The DNS of the stg spoke (Profile and the zone nonprd) and of prd (Profile only), then one plan per validation rule.
# The AWS provider is a mock: nothing reaches an account.

mock_provider "aws" {}

variables {
  name       = "svp-lab-net-stg"
  vpc_id     = "vpc-0aaaaaaaaaaaaaaa1"
  profile_id = "rp-0123456789abcdef"
  zone_ids   = { nonprd = "Z0123456789ABCDEFGHIJ" }
}

run "stg" {
  command = plan

  assert {
    condition = (aws_route53profiles_association.this.profile_id == "rp-0123456789abcdef" &&
    aws_route53profiles_association.this.resource_id == "vpc-0aaaaaaaaaaaaaaa1")
    error_message = "The Profile must be associated with the spoke VPC."
  }

  assert {
    condition = (keys(aws_route53_zone_association.this) == ["nonprd"] &&
      aws_route53_zone_association.this["nonprd"].zone_id == "Z0123456789ABCDEFGHIJ" &&
    aws_route53_zone_association.this["nonprd"].vpc_id == "vpc-0aaaaaaaaaaaaaaa1")
    error_message = "stg must join the zone nonprd directly."
  }
}

run "prd" {
  command = plan

  variables {
    name     = "svp-lab-net-prd"
    vpc_id   = "vpc-0bbbbbbbbbbbbbbb2"
    zone_ids = {}
  }

  assert {
    condition     = length(aws_route53_zone_association.this) == 0
    error_message = "prd must get its zones from the Profile only."
  }
}

run "profile_id_invalid" {
  command = plan

  variables {
    profile_id = "Z0123456789ABCDEFGHIJ"
  }

  expect_failures = [var.profile_id]
}

run "zone_id_invalid" {
  command = plan

  variables {
    zone_ids = { nonprd = "rp-0123" }
  }

  expect_failures = [var.zone_ids]
}
