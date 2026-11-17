# Pilot light of svp's data tier: PostgreSQL and media in ap-southeast-1, a cross-Region read replica, replicated
# automated backups and replicated media in us-east-1, and a private name db.<zone> that the drill fails over.
# Design notes: multi-region-dr/README.md.

locals {
  lab       = "svp-lab-dr"
  zone_name = "svp-lab-dr.internal"
  primary   = "ap-southeast-1"
  dr        = "us-east-1"
  db_name   = "svp_lab"
  db_user   = "svp_admin"
}

# A new value on every run, written only when password_version changes: never in the plan or the state.
ephemeral "aws_secretsmanager_random_password" "master" {
  provider            = aws.primary
  password_length     = 32
  exclude_punctuation = true
}

module "primary_network" {
  source    = "../modules/network"
  providers = { aws = aws.primary }

  name       = "${local.lab}-primary"
  cidr_block = "10.65.0.0/20"
}

module "dr_network" {
  source    = "../modules/network"
  providers = { aws = aws.dr }

  name       = "${local.lab}-dr"
  cidr_block = "10.65.16.0/20"
}

module "db_secret" {
  source    = "../modules/db-secret"
  providers = { aws = aws.primary }

  name             = "${local.lab}-db-master"
  replica_region   = local.dr
  password         = ephemeral.aws_secretsmanager_random_password.master.random_password
  password_version = var.password_version
}

module "primary_bastion" {
  source    = "../modules/bastion"
  providers = { aws = aws.primary }

  name       = "${local.lab}-bastion-primary"
  vpc_id     = module.primary_network.vpc_id
  vpc_cidr   = module.primary_network.vpc_cidr
  subnet_id  = module.primary_network.public_subnet_id
  secret_arn = module.db_secret.arn
  user_data  = templatefile("${path.module}/user-data.sh.tftpl", local.user_data_vars[local.primary])
}

module "dr_bastion" {
  source    = "../modules/bastion"
  providers = { aws = aws.dr }

  name       = "${local.lab}-bastion-dr"
  vpc_id     = module.dr_network.vpc_id
  vpc_cidr   = module.dr_network.vpc_cidr
  subnet_id  = module.dr_network.public_subnet_id
  secret_arn = module.db_secret.replica_arn
  user_data  = templatefile("${path.module}/user-data.sh.tftpl", local.user_data_vars[local.dr])
}

locals {
  user_data_vars = {
    for region in [local.primary, local.dr] : region => {
      region    = region
      secret_id = module.db_secret.name
      dns_name  = "db.${local.zone_name}"
      db_name   = local.db_name
      db_user   = local.db_user
      heartbeat = base64encode(file("${path.module}/../scripts/heartbeat.sh"))
    }
  }
}

module "primary_db" {
  source    = "../modules/postgres"
  providers = { aws = aws.primary }

  name                     = "${local.lab}-primary"
  vpc_id                   = module.primary_network.vpc_id
  subnet_ids               = module.primary_network.db_subnet_ids
  client_security_group_id = module.primary_bastion.security_group_id
  db_name                  = local.db_name
  master_username          = local.db_user
  master_password          = ephemeral.aws_secretsmanager_random_password.master.random_password
  password_version         = var.password_version
}

# RDS needs a key of the destination Region for the encrypted replica and backups. Describing the predefined alias
# makes KMS associate it with the AWS managed key aws/rds of us-east-1, even before any RDS resource there.
data "aws_kms_key" "dr_rds" {
  provider = aws.dr
  key_id   = "alias/aws/rds"
}

module "dr_db" {
  source    = "../modules/postgres"
  providers = { aws = aws.dr }

  name                     = "${local.lab}-replica"
  vpc_id                   = module.dr_network.vpc_id
  subnet_ids               = module.dr_network.db_subnet_ids
  client_security_group_id = module.dr_bastion.security_group_id
  replicate_source_db      = module.primary_db.arn
  replicate_backups_from   = module.primary_db.arn
  kms_key_arn              = data.aws_kms_key.dr_rds.arn
}

module "primary_media" {
  source    = "../modules/bucket"
  providers = { aws = aws.primary }

  name = "${local.lab}-media-${var.account_id}-${local.primary}"
}

module "dr_media" {
  source    = "../modules/bucket"
  providers = { aws = aws.dr }

  name = "${local.lab}-media-${var.account_id}-${local.dr}"
}

module "media_replication" {
  source    = "../modules/crr"
  providers = { aws = aws.primary }

  name                   = "${local.lab}-media-replication"
  source_bucket_name     = module.primary_media.name
  destination_bucket_arn = module.dr_media.arn
}

# The switch alarm lives in the DR Region, so the failover does not depend on the Region it leaves.
module "dns" {
  source    = "../modules/dns-failover"
  providers = { aws = aws.dr }

  name      = local.lab
  zone_name = local.zone_name
  vpcs = [
    { vpc_id = module.primary_network.vpc_id, region = local.primary },
    { vpc_id = module.dr_network.vpc_id, region = local.dr },
  ]
  primary_target   = module.primary_db.address
  secondary_target = module.dr_db.address
}
