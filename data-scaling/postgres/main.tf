# The postgres part of the data-scaling lab: Aurora PostgreSQL with a reader, RDS for PostgreSQL Multi-AZ with a read
# replica, and RDS Proxy in front of Aurora, each behind a variable, plus the loader that measures them. One secret
# holds the one master password of all three. Design notes: data-scaling/README.md.

locals {
  lab     = "svp-lab-ds-pg"
  db_name = "svp_lab"
  db_user = "svp_admin"
}

# A new value on every run, written into the secret only when password_version changes: never in the plan or the
# state. Letters and digits need no quoting in a password file or a connection string.
ephemeral "aws_secretsmanager_random_password" "master" {
  password_length     = 32
  exclude_punctuation = true
}

module "network" {
  source = "../modules/network"

  name       = local.lab
  cidr_block = "10.67.0.0/20"
}

module "db_secret" {
  source = "../modules/db-secret"

  name             = "${local.lab}-master"
  username         = local.db_user
  password         = ephemeral.aws_secretsmanager_random_password.master.random_password
  password_version = var.password_version
}

# The databases take the password back from the secret's current version, not from the random value above: a database
# created by a later apply, or after an apply that failed past the secret, then gets what the secret holds.
ephemeral "aws_secretsmanager_secret_version" "master" {
  secret_id  = module.db_secret.arn
  version_id = module.db_secret.version_id
}

locals {
  master_password = jsondecode(ephemeral.aws_secretsmanager_secret_version.master.secret_string).password
}

# The boot script names no endpoint: turning a database on or off leaves the loader as it is.
module "loader" {
  source = "../modules/loader"

  name        = "${local.lab}-loader"
  vpc_id      = module.network.vpc_id
  vpc_cidr    = module.network.vpc_cidr
  subnet_id   = module.network.public_subnet_id
  data_ports  = [5432]
  secret_arns = [module.db_secret.arn]

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    region    = "ap-southeast-1"
    secret_id = module.db_secret.name
    db_name   = local.db_name
    pg        = base64gzip(file("${path.module}/../scripts/pg.sh"))
  })
}

module "aurora" {
  source = "../modules/aurora"
  count  = var.aurora ? 1 : 0

  name       = "svp-lab-ds-aurora"
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.data_subnet_ids
  client_security_group_ids = merge(
    { loader = module.loader.security_group_id },
    var.proxy ? { proxy = module.rds_proxy[0].security_group_id } : {},
  )
  db_name          = local.db_name
  master_username  = local.db_user
  master_password  = local.master_password
  password_version = var.password_version
}

module "rds" {
  source = "../modules/rds"
  count  = var.rds ? 1 : 0

  name                     = "svp-lab-ds-rds"
  vpc_id                   = module.network.vpc_id
  subnet_ids               = module.network.data_subnet_ids
  client_security_group_id = module.loader.security_group_id
  db_name                  = local.db_name
  master_username          = local.db_user
  master_password          = local.master_password
  password_version         = var.password_version
}

module "rds_proxy" {
  source = "../modules/rds-proxy"
  count  = var.proxy ? 1 : 0

  name                     = "svp-lab-ds-proxy"
  vpc_id                   = module.network.vpc_id
  subnet_ids               = module.network.data_subnet_ids
  client_security_group_id = module.loader.security_group_id
  target_security_group_id = module.aurora[0].security_group_id
  cluster_identifier       = module.aurora[0].cluster_identifier
  secret_arn               = module.db_secret.arn
}
