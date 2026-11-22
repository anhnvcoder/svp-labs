# Mock providers cannot answer an ephemeral resource: the copy that scripts/inventory.sh plans has no ephemeral block,
# and these fake passwords stand in for the values the root reads from them.

module "source_db" {
  password = "inventory-fake-password"
}

module "source_secret" {
  password = "inventory-fake-password"
}

module "target_db" {
  master_password = "inventory-fake-password"
}

module "target_secret" {
  password = "inventory-fake-password"
}
