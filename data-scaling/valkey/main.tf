# The valkey part of the data-scaling lab: ElastiCache for Valkey with cluster mode enabled (svp-lab-ds-cme) and
# disabled (svp-lab-ds-cmd), plus the loader that measures them. One secret holds the password of the one user of
# both groups. Design notes: data-scaling/README.md.

locals {
  lab = "svp-lab-ds-kv"
}

# A new value on every run, written into the secret only when password_version changes: never in the plan or the
# state. Letters and digits need no quoting on the command line of valkey-benchmark.
ephemeral "aws_secretsmanager_random_password" "app" {
  password_length     = 32
  exclude_punctuation = true
}

module "network" {
  source = "../modules/network"

  name       = local.lab
  cidr_block = "10.67.16.0/20"
}

module "valkey" {
  source = "../modules/valkey"

  name                     = local.lab
  vpc_id                   = module.network.vpc_id
  subnet_ids               = module.network.data_subnet_ids
  client_security_group_id = module.loader.security_group_id
  shards                   = var.shards
  password                 = ephemeral.aws_secretsmanager_random_password.app.random_password
  user_password            = jsondecode(ephemeral.aws_secretsmanager_secret_version.app.secret_string).password
  password_version         = var.password_version
}

# The user takes the password back from the secret's current version, not from the random value above: a user made
# after an apply that failed past the secret then gets what the secret holds.
ephemeral "aws_secretsmanager_secret_version" "app" {
  secret_id  = module.valkey.secret_arn
  version_id = module.valkey.secret_version_id
}

# The boot script names no endpoint: the session script looks them up and passes them to kv.sh.
module "loader" {
  source = "../modules/loader"

  name        = "${local.lab}-loader"
  vpc_id      = module.network.vpc_id
  vpc_cidr    = module.network.vpc_cidr
  subnet_id   = module.network.public_subnet_id
  data_ports  = [6379]
  secret_arns = [module.valkey.secret_arn]

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    region    = "ap-southeast-1"
    secret_id = module.valkey.secret_name
    kv        = base64gzip(file("${path.module}/../scripts/kv.sh"))
  })
}
