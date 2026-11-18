# The valkey part of the data-scaling lab: two ElastiCache for Valkey replication groups of the same engine and node
# type, one with cluster mode on (shards of one primary and one replica) and one with it off (one primary, one
# replica), behind one RBAC user over TLS. The secret is the one source of that user's password: the root reads it back
# for the user, so neither the plan nor the state holds it. Design notes: data-scaling/README.md.

locals {
  engine_major_version = split(".", var.engine_version)[0]

  # The lab's scripts write svp:* keys and valkey-benchmark its key* keys, in any database. Without -@dangerous the
  # read and write categories would also allow FLUSHDB and KEYS; the cluster subcommands are the read-only ones the
  # cluster-aware clients and the scripts ask.
  access_string = join(" ", [
    "on ~svp:* ~key* resetchannels -@all +@read +@write +@connection -@dangerous",
    "+cluster|keyslot +cluster|nodes +cluster|shards +cluster|slots +cluster|info",
  ])
}

################################################################################
# Secret
################################################################################

# Forced deletion and the AWS managed key aws/secretsmanager: the lab destroys everything at the end of the session.
resource "aws_secretsmanager_secret" "this" {
  name                    = "${var.name}-app"
  description             = "Valkey user of the data-scaling lab, read by the loader's scripts"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "this" {
  secret_id = aws_secretsmanager_secret.this.id
  secret_string_wo = jsonencode({
    username = "${var.name}-app"
    password = var.password
  })
  secret_string_wo_version = var.password_version
}

################################################################################
# User
################################################################################

resource "aws_elasticache_user" "app" {
  user_id       = "${var.name}-app"
  user_name     = "${var.name}-app"
  engine        = "valkey"
  access_string = local.access_string

  passwords_wo         = var.user_password
  passwords_wo_version = var.password_version
}

# No default user in the group: a group of engine valkey needs none, and once the group is attached ElastiCache
# refuses a client that does not log in as a member.
resource "aws_elasticache_user_group" "this" {
  user_group_id = var.name
  engine        = "valkey"
  user_ids      = [aws_elasticache_user.app.user_id]
}

################################################################################
# Network
################################################################################

resource "aws_elasticache_subnet_group" "this" {
  name        = var.name
  description = "Data subnets of the Valkey groups of ${var.name}"
  subnet_ids  = var.subnet_ids
}

# One group for both replication groups. No egress rule: Terraform removes the allow-all rule AWS puts on a new
# group, and the nodes open no connection outside ElastiCache replication.
resource "aws_security_group" "this" {
  name        = "${var.name}-valkey"
  description = "Valkey of ${var.name}, 6379 from the loader only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-valkey"
  }
}

resource "aws_vpc_security_group_ingress_rule" "client" {
  security_group_id            = aws_security_group.this.id
  description                  = "Valkey from the loader"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = var.client_security_group_id
}

################################################################################
# Replication groups
################################################################################

# The engine's defaults but for the one parameter that tells the two groups apart, written out where it shows.
resource "aws_elasticache_parameter_group" "this" {
  for_each = { cme = "yes", cmd = "no" }

  name        = "svp-lab-ds-${each.key}-valkey${local.engine_major_version}"
  description = "Valkey ${local.engine_major_version} of svp-lab-ds-${each.key}, cluster-enabled ${each.value}"
  family      = "valkey${local.engine_major_version}"

  parameter {
    name  = "cluster-enabled"
    value = each.value
  }
}

# Cluster mode on: keys spread over num_node_groups shards by hash slot, each shard a primary and a replica in
# another zone. A change of shards is an online reshard; the session script starts it through the API so that it can
# time it, then the variable follows.
resource "aws_elasticache_replication_group" "cme" {
  replication_group_id = "svp-lab-ds-cme"
  description          = "Valkey with cluster mode enabled, data-scaling lab"

  engine               = "valkey"
  engine_version       = var.engine_version
  node_type            = var.node_type
  cluster_mode         = "enabled"
  num_node_groups      = var.shards
  parameter_group_name = aws_elasticache_parameter_group.this["cme"].name
  port                 = 6379

  replicas_per_node_group    = 1
  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.this.id]

  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  at_rest_encryption_enabled = true
  user_group_ids             = [aws_elasticache_user_group.this.user_group_id]

  # Disposable data: no automatic snapshot, and none at destroy (no final_snapshot_identifier).
  snapshot_retention_limit = 0
  apply_immediately        = true

  tags = {
    Name = "svp-lab-ds-cme"
  }
}

# Cluster mode off: one primary holds every key, a replica in another zone takes over on failover. The same engine,
# node type and user as the group above, so that the client's view is the only difference measured.
resource "aws_elasticache_replication_group" "cmd" {
  replication_group_id = "svp-lab-ds-cmd"
  description          = "Valkey with cluster mode disabled, data-scaling lab"

  engine               = "valkey"
  engine_version       = var.engine_version
  node_type            = var.node_type
  cluster_mode         = "disabled"
  num_cache_clusters   = 2
  parameter_group_name = aws_elasticache_parameter_group.this["cmd"].name
  port                 = 6379

  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.this.id]

  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  at_rest_encryption_enabled = true
  user_group_ids             = [aws_elasticache_user_group.this.user_group_id]

  snapshot_retention_limit = 0
  apply_immediately        = true

  tags = {
    Name = "svp-lab-ds-cmd"
  }
}
