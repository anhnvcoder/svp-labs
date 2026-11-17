# The caller's own credentials in the management account (AWS_PROFILE=anhnv-sso), where Organizations answers.
provider "aws" {
  region = "ap-southeast-1"

  # A wrong profile or account id fails at the first API call instead of changing another account.
  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = {
      Project   = "svp"
      ManagedBy = "terraform"
      Lab       = "multi-account-networking"
    }
  }
}
