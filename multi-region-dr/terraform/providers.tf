# State stays local (no backend block) and is deleted after the destroy of the session. The organization allows only
# these two Regions to member accounts.

locals {
  tags = {
    Project   = "svp"
    ManagedBy = "terraform"
    Lab       = "multi-region-dr"
  }
}

provider "aws" {
  alias               = "primary"
  region              = "ap-southeast-1"
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = local.tags
  }
}

provider "aws" {
  alias               = "dr"
  region              = "us-east-1"
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = local.tags
  }
}
