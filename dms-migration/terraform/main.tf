# svp's engagement database "on premises" (PostgreSQL on EC2 in a VPC of its own) migrated by DMS, full load then CDC,
# into RDS for PostgreSQL in the AWS-side VPC; a VPC peering plays the VPN or Direct Connect. Every instance sits in
# the first availability zone, where data transfer is free. Design notes: dms-migration/README.md.

locals {
  lab        = "svp-lab-dms"
  db_name    = "svp_engagement"
  dms_user   = "svp_dms"
  admin_user = "svp_admin"
  parameter  = "/svp-lab-dms/source/svp_dms-password"
}

# New values on every run, written only when a version variable changes: never in the plan or the state. DMS refuses
# some punctuation in endpoint passwords, and letters and digits also need no quoting in SQL or a password file.
ephemeral "aws_secretsmanager_random_password" "source" {
  password_length     = 32
  exclude_punctuation = true
}

ephemeral "aws_secretsmanager_random_password" "target" {
  password_length     = 32
  exclude_punctuation = true
}

module "onprem_network" {
  source = "../modules/network"

  name       = "${local.lab}-onprem"
  cidr_block = "192.168.16.0/20"
  subnets    = "public"
}

module "aws_network" {
  source = "../modules/network"

  name       = "${local.lab}-aws"
  cidr_block = "10.66.0.0/20"
  subnets    = "private"
}

module "peering" {
  source = "../modules/peering"

  name = "${local.lab}-peering"
  requester = {
    vpc_id         = module.onprem_network.vpc_id
    cidr           = module.onprem_network.vpc_cidr
    route_table_id = module.onprem_network.route_table_id
  }
  accepter = {
    vpc_id         = module.aws_network.vpc_id
    cidr           = module.aws_network.vpc_cidr
    route_table_id = module.aws_network.route_table_id
  }
}

module "source_db" {
  source = "../modules/source-db"

  name                    = "${local.lab}-source"
  vpc_id                  = module.onprem_network.vpc_id
  subnet_id               = module.onprem_network.subnet_ids[0]
  dms_cidrs               = module.aws_network.subnet_cidrs
  target_cidr             = module.aws_network.vpc_cidr
  password_parameter_name = local.parameter
  password                = ephemeral.aws_secretsmanager_random_password.source.random_password
  password_version        = var.source_password_version
  target_secret_arn       = module.target_secret.arn
  task_arn                = module.dms.task_arn

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    db_name       = local.db_name
    dms_user      = local.dms_user
    dms_cidrs     = module.aws_network.subnet_cidrs
    parameter     = local.parameter
    target_secret = "${local.lab}-target"
    pgload        = base64gzip(file("${path.module}/../scripts/pgload.sh"))
  })
}

module "source_secret" {
  source = "../modules/endpoint-secret"

  name             = "${local.lab}-source"
  description      = "${local.db_name} on the on-premises stand-in, user ${local.dms_user}: source endpoint of DMS"
  username         = local.dms_user
  password         = ephemeral.aws_secretsmanager_random_password.source.random_password
  host             = module.source_db.private_ip
  password_version = var.source_password_version
}

module "target_db" {
  source = "../modules/target-db"

  name                  = "${local.lab}-target"
  vpc_id                = module.aws_network.vpc_id
  subnet_ids            = module.aws_network.subnet_ids
  availability_zone     = module.aws_network.availability_zone
  dms_security_group_id = module.dms.security_group_id
  client_cidrs          = module.onprem_network.subnet_cidrs
  db_name               = local.db_name
  master_username       = local.admin_user
  master_password       = ephemeral.aws_secretsmanager_random_password.target.random_password
  password_version      = var.target_password_version
}

module "target_secret" {
  source = "../modules/endpoint-secret"

  name             = "${local.lab}-target"
  description      = "${local.db_name} on RDS, master user ${local.admin_user}: target endpoint of DMS and the application after the cutover"
  username         = local.admin_user
  password         = ephemeral.aws_secretsmanager_random_password.target.random_password
  host             = module.target_db.address
  password_version = var.target_password_version
}

module "dms" {
  source = "../modules/dms"

  name              = local.lab
  vpc_id            = module.aws_network.vpc_id
  subnet_ids        = module.aws_network.subnet_ids
  availability_zone = module.aws_network.availability_zone
  source_cidrs      = module.onprem_network.subnet_cidrs
  target_cidr       = module.aws_network.vpc_cidr
  create_vpc_role   = var.create_dms_vpc_role
  create_logs_role  = var.create_dms_logs_role
  database_name     = local.db_name
  source_secret_arn = module.source_secret.arn
  target_secret_arn = module.target_secret.arn
  rds_ca_bundle     = var.rds_ca_bundle
}
