# Mock providers cannot answer an ephemeral resource: the copy that scripts/inventory.sh plans has no ephemeral block,
# and these fake passwords stand in for the values the root reads from them.

module "db_secret" {
  password = "inventory-fake-password"
}

locals {
  master_password = "inventory-fake-password"
}
