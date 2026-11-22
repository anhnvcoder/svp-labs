# Plan of multi-account-networking/account in a management account whose organization exists (svp-infra builds it)
# and holds no OU Infrastructure nor account svp-network yet.

mock_provider "aws" {
  mock_data "aws_organizations_organization" {
    defaults = {
      id    = "o-0000000000"
      roots = [{ id = "r-0000", arn = "arn:aws:organizations::000000000000:root/o-0000000000/r-0000", name = "Root", policy_types = [] }]
    }
  }
}

variables {
  management_account_id = "000000000000"
}

run "inventory" {
  command = plan
}
