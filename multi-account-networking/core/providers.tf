locals {
  region = "ap-southeast-1"

  default_tags = {
    Project   = "svp"
    ManagedBy = "terraform"
    Lab       = "multi-account-networking"
  }
}

# Terraform has no loop over provider blocks, hence one block per account, all in ap-southeast-1. Management uses the
# caller's own credentials (AWS_PROFILE=anhnv-sso): only it can turn on sharing in the organization.
provider "aws" {
  alias  = "management"
  region = local.region

  # A wrong profile or account id fails at the first API call instead of changing another account.
  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = local.default_tags
  }
}

# Member accounts through OrganizationAccountAccessRole, which Organizations put in each account it created.
provider "aws" {
  alias  = "network"
  region = local.region

  allowed_account_ids = [var.network_account_id]

  assume_role {
    role_arn     = "arn:aws:iam::${var.network_account_id}:role/OrganizationAccountAccessRole"
    session_name = "svp-lab-net"
  }

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "stg"
  region = local.region

  allowed_account_ids = [var.stg_account_id]

  assume_role {
    role_arn     = "arn:aws:iam::${var.stg_account_id}:role/OrganizationAccountAccessRole"
    session_name = "svp-lab-net"
  }

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "prd"
  region = local.region

  allowed_account_ids = [var.prd_account_id]

  assume_role {
    role_arn     = "arn:aws:iam::${var.prd_account_id}:role/OrganizationAccountAccessRole"
    session_name = "svp-lab-net"
  }

  default_tags {
    tags = local.default_tags
  }
}
