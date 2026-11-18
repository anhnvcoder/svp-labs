# Validation rules of the variables, then the two groups the lab compares: cluster mode on with the given shards and
# off, both Multi-AZ with automatic failover over TLS behind the one user of the group, the password through
# write-only arguments only, 6379 from the loader only, nothing left after the destroy. The AWS provider is a mock.

mock_provider "aws" {}

variables {
  name                     = "svp-lab-ds-kv"
  vpc_id                   = "vpc-0123456789abcdef0"
  subnet_ids               = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
  client_security_group_id = "sg-0aaaaaaaaaaaaaaa1"
  password                 = "test-only-not-a-secret"
  user_password            = "test-only-not-a-secret"
  password_version         = 1
}

run "groups" {
  command = plan

  variables {
    shards = 3
  }

  assert {
    condition     = aws_elasticache_replication_group.cme.replication_group_id == "svp-lab-ds-cme" && aws_elasticache_replication_group.cme.cluster_mode == "enabled"
    error_message = "svp-lab-ds-cme runs with cluster mode enabled."
  }

  assert {
    condition     = aws_elasticache_replication_group.cme.num_node_groups == 3 && aws_elasticache_replication_group.cme.replicas_per_node_group == 1
    error_message = "svp-lab-ds-cme has the shards given, one replica each."
  }

  assert {
    condition     = aws_elasticache_replication_group.cme.parameter_group_name == "svp-lab-ds-cme-valkey9" && aws_elasticache_parameter_group.this["cme"].family == "valkey9" && one(aws_elasticache_parameter_group.this["cme"].parameter).value == "yes"
    error_message = "svp-lab-ds-cme takes a parameter group of its major with cluster-enabled yes."
  }

  assert {
    condition     = aws_elasticache_replication_group.cmd.replication_group_id == "svp-lab-ds-cmd" && aws_elasticache_replication_group.cmd.cluster_mode == "disabled" && aws_elasticache_replication_group.cmd.num_cache_clusters == 2
    error_message = "svp-lab-ds-cmd runs with cluster mode disabled: one primary and one replica."
  }

  assert {
    condition     = aws_elasticache_replication_group.cmd.parameter_group_name == "svp-lab-ds-cmd-valkey9" && one(aws_elasticache_parameter_group.this["cmd"].parameter).name == "cluster-enabled" && one(aws_elasticache_parameter_group.this["cmd"].parameter).value == "no"
    error_message = "svp-lab-ds-cmd takes a parameter group of its major with cluster-enabled no."
  }

  assert {
    condition = alltrue([for g in [aws_elasticache_replication_group.cme, aws_elasticache_replication_group.cmd] :
    g.engine == "valkey" && g.engine_version == "9.1" && g.node_type == "cache.t4g.micro" && g.port == 6379])
    error_message = "Both groups run Valkey 9.1 on cache.t4g.micro, port 6379."
  }

  assert {
    condition = alltrue([for g in [aws_elasticache_replication_group.cme, aws_elasticache_replication_group.cmd] :
    g.transit_encryption_enabled && g.transit_encryption_mode == "required" && g.at_rest_encryption_enabled])
    error_message = "Both groups require TLS and encrypt their data at rest."
  }

  assert {
    condition = alltrue([for g in [aws_elasticache_replication_group.cme, aws_elasticache_replication_group.cmd] :
    g.automatic_failover_enabled && g.multi_az_enabled])
    error_message = "Both groups run Multi-AZ with automatic failover."
  }

  assert {
    condition = alltrue([for g in [aws_elasticache_replication_group.cme, aws_elasticache_replication_group.cmd] :
    g.user_group_ids == toset(["svp-lab-ds-kv"]) && g.auth_token == null && g.auth_token_wo_version == null])
    error_message = "Both groups authenticate through the user group svp-lab-ds-kv, with no AUTH token."
  }

  assert {
    condition = alltrue([for g in [aws_elasticache_replication_group.cme, aws_elasticache_replication_group.cmd] :
    g.snapshot_retention_limit == 0 && g.final_snapshot_identifier == null])
    error_message = "No automatic snapshot and no final snapshot."
  }

  assert {
    condition = alltrue([for g in [aws_elasticache_replication_group.cme, aws_elasticache_replication_group.cmd] :
    length(g.security_group_ids) == 1 && g.subnet_group_name == "svp-lab-ds-kv"])
    error_message = "Both groups sit in the data subnets behind the part's security group."
  }
}

run "users" {
  command = plan

  assert {
    condition     = aws_elasticache_user_group.this.engine == "valkey" && aws_elasticache_user_group.this.user_ids == toset(["svp-lab-ds-kv-app"])
    error_message = "The user group holds the lab's user alone: no default user, so a client that does not log in is refused."
  }

  assert {
    condition     = aws_elasticache_user.app.user_name == "svp-lab-ds-kv-app" && aws_elasticache_user.app.engine == "valkey" && startswith(aws_elasticache_user.app.access_string, "on ")
    error_message = "The user svp-lab-ds-kv-app is on."
  }

  assert {
    condition     = strcontains(aws_elasticache_user.app.access_string, "-@dangerous") && !strcontains(aws_elasticache_user.app.access_string, "~*") && !strcontains(aws_elasticache_user.app.access_string, "+@all")
    error_message = "The user reaches the lab's keys only, without the dangerous commands."
  }

  assert {
    condition     = aws_elasticache_user.app.passwords_wo_version == 1 && aws_elasticache_user.app.passwords == null
    error_message = "The password goes through passwords_wo only."
  }

  assert {
    condition     = aws_secretsmanager_secret.this.name == "svp-lab-ds-kv-app" && aws_secretsmanager_secret.this.recovery_window_in_days == 0
    error_message = "The secret svp-lab-ds-kv-app is deleted at once with the destroy of a session."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.this.secret_string_wo_version == 1 && aws_secretsmanager_secret_version.this.secret_string == null
    error_message = "The value goes through the write-only argument, never secret_string."
  }

  assert {
    condition     = aws_secretsmanager_secret.this.kms_key_id == null && length(aws_secretsmanager_secret.this.replica) == 0
    error_message = "The secret uses the AWS managed key and stays in its Region."
  }
}

run "network" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.client.referenced_security_group_id == "sg-0aaaaaaaaaaaaaaa1" && aws_vpc_security_group_ingress_rule.client.cidr_ipv4 == null
    error_message = "Only the loader's security group is let in, never an address range."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.client.from_port == 6379 && aws_vpc_security_group_ingress_rule.client.to_port == 6379 && aws_vpc_security_group_ingress_rule.client.ip_protocol == "tcp"
    error_message = "The rule opens 6379/tcp only."
  }

  assert {
    condition     = toset(aws_elasticache_subnet_group.this.subnet_ids) == toset(["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"])
    error_message = "The subnet group spans the two data subnets."
  }
}

run "one_shard" {
  command = plan

  variables {
    shards = 1
  }

  assert {
    condition     = aws_elasticache_replication_group.cme.num_node_groups == 1 && aws_elasticache_replication_group.cme.cluster_mode == "enabled"
    error_message = "One shard still runs with cluster mode enabled."
  }
}

run "default_shards" {
  command = plan

  assert {
    condition     = aws_elasticache_replication_group.cme.num_node_groups == 2
    error_message = "svp-lab-ds-cme starts with two shards."
  }
}

run "shards_zero" {
  command = plan

  variables {
    shards = 0
  }

  expect_failures = [var.shards]
}

run "shards_too_many" {
  command = plan

  variables {
    shards = 6
  }

  expect_failures = [var.shards]
}

run "name_outside_the_lab" {
  command = plan

  variables {
    name = "svp-prd"
  }

  expect_failures = [var.name]
}

run "subnet_ids_one_zone" {
  command = plan

  variables {
    subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1"]
  }

  expect_failures = [var.subnet_ids]
}

run "client_not_a_group" {
  command = plan

  variables {
    client_security_group_id = "10.67.16.0/20"
  }

  expect_failures = [var.client_security_group_id]
}

run "node_type_not_allowed" {
  command = plan

  variables {
    node_type = "cache.r7g.large"
  }

  expect_failures = [var.node_type]
}

run "engine_version_patch" {
  command = plan

  variables {
    engine_version = "9.1.0"
  }

  expect_failures = [var.engine_version]
}

run "password_version_zero" {
  command = plan

  variables {
    password_version = 0
  }

  expect_failures = [var.password_version]
}
