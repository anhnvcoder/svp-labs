# State stays local (no backend block) and is deleted after the destroy of the session.

provider "aws" {
  region              = "ap-southeast-1"
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = "svp"
      ManagedBy = "terraform"
      Lab       = "dms-migration"
    }
  }
}
