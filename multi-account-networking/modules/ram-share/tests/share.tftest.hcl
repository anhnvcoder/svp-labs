# The share of the transit gateway with stg and prd, then one plan per validation rule. The AWS provider is a mock:
# nothing reaches an account.

mock_provider "aws" {}

variables {
  name          = "svp-lab-net-tgw"
  resource_arns = { tgw = "arn:aws:ec2:ap-southeast-1:555555555555:transit-gateway/tgw-0123456789abcdef0" }
  principals    = ["000000000000", "444444444444"]
}

run "share" {
  command = plan

  assert {
    condition     = aws_ram_resource_share.this.allow_external_principals == false
    error_message = "The share must stay inside the organization."
  }

  assert {
    condition     = toset(keys(aws_ram_principal_association.this)) == toset(["000000000000", "444444444444"])
    error_message = "Each given account, and no other principal, must receive the share."
  }

  assert {
    condition = (keys(aws_ram_resource_association.this) == ["tgw"] &&
    aws_ram_resource_association.this["tgw"].resource_arn == "arn:aws:ec2:ap-southeast-1:555555555555:transit-gateway/tgw-0123456789abcdef0")
    error_message = "The share must hold exactly the given resource."
  }
}

run "principal_is_organization" {
  command = plan

  variables {
    principals = ["arn:aws:organizations::111111111111:organization/o-exampleorgid"]
  }

  expect_failures = [var.principals]
}

run "principals_empty" {
  command = plan

  variables {
    principals = []
  }

  expect_failures = [var.principals]
}

run "principals_repeated" {
  command = plan

  variables {
    principals = ["000000000000", "000000000000"]
  }

  expect_failures = [var.principals]
}

run "resource_arns_empty" {
  command = plan

  variables {
    resource_arns = {}
  }

  expect_failures = [var.resource_arns]
}
