# Validation rules of the variables, then the cluster the lab measures: a writer and a reader in two zones, the master
# password through the write-only argument only, encrypted storage, 5432 from the given groups only, nothing left
# after the destroy. The AWS provider is a mock that returns the engine version and zone below.

mock_provider "aws" {
  mock_data "aws_rds_engine_version" {
    defaults = {
      version_actual = "17.7"
    }
  }

  mock_data "aws_subnet" {
    defaults = {
      availability_zone = "ap-southeast-1a"
    }
  }
}

variables {
  name       = "svp-lab-ds-aurora"
  vpc_id     = "vpc-0123456789abcdef0"
  subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
  client_security_group_ids = {
    loader = "sg-0aaaaaaaaaaaaaaa1"
    proxy  = "sg-0bbbbbbbbbbbbbbb2"
  }
  master_password  = "test-only-not-a-secret"
  password_version = 1
}

run "cluster" {
  command = plan

  assert {
    condition     = aws_rds_cluster.this.engine == "aurora-postgresql" && aws_rds_cluster.this.engine_version == "17.7" && aws_rds_cluster.this.cluster_identifier == "svp-lab-ds-aurora"
    error_message = "The cluster is Aurora PostgreSQL at the newest minor of 17."
  }

  assert {
    condition     = aws_rds_cluster_instance.writer.cluster_identifier == "svp-lab-ds-aurora" && aws_rds_cluster_instance.reader.cluster_identifier == "svp-lab-ds-aurora"
    error_message = "The cluster has two instances: a writer and a reader."
  }

  assert {
    condition     = aws_rds_cluster_instance.writer.identifier == "svp-lab-ds-aurora-1" && aws_rds_cluster_instance.reader.identifier == "svp-lab-ds-aurora-2"
    error_message = "The instances carry the names the session script looks up."
  }

  assert {
    condition     = aws_rds_cluster_instance.writer.instance_class == "db.t4g.medium" && aws_rds_cluster_instance.reader.instance_class == "db.t4g.medium"
    error_message = "Both instances are db.t4g.medium by default."
  }

  assert {
    condition     = aws_rds_cluster_instance.writer.availability_zone == data.aws_subnet.data[0].availability_zone && aws_rds_cluster_instance.reader.availability_zone == data.aws_subnet.data[1].availability_zone
    error_message = "The writer sits in the zone of the first data subnet, the reader in the zone of the second."
  }

  assert {
    condition     = aws_rds_cluster.this.master_password_wo_version == 1 && aws_rds_cluster.this.master_password == null && aws_rds_cluster.this.manage_master_user_password == null
    error_message = "The master password goes through master_password_wo only; RDS manages no second password."
  }

  assert {
    condition     = aws_rds_cluster.this.storage_encrypted && !aws_rds_cluster_instance.writer.publicly_accessible && !aws_rds_cluster_instance.reader.publicly_accessible
    error_message = "Storage is encrypted and no instance is public."
  }

  assert {
    condition     = aws_rds_cluster.this.backup_retention_period == 1 && aws_rds_cluster.this.delete_automated_backups && aws_rds_cluster.this.skip_final_snapshot && !aws_rds_cluster.this.deletion_protection
    error_message = "One day of backups, deleted with the cluster, and no final snapshot."
  }

  assert {
    condition     = !aws_rds_cluster_instance.writer.performance_insights_enabled && aws_rds_cluster_instance.writer.monitoring_interval == 0
    error_message = "No Performance Insights nor Enhanced Monitoring: no measure needs them."
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.client)) == toset(["loader", "proxy"]) && aws_vpc_security_group_ingress_rule.client["loader"].referenced_security_group_id == "sg-0aaaaaaaaaaaaaaa1" && aws_vpc_security_group_ingress_rule.client["proxy"].referenced_security_group_id == "sg-0bbbbbbbbbbbbbbb2"
    error_message = "5432 is open to the loader and the proxy, by security group."
  }

  assert {
    condition     = alltrue([for r in aws_vpc_security_group_ingress_rule.client : r.from_port == 5432 && r.to_port == 5432 && r.ip_protocol == "tcp" && r.cidr_ipv4 == null])
    error_message = "Each rule opens 5432 only, and never to an address range."
  }
}

run "loader_only" {
  command = plan

  variables {
    client_security_group_ids = {
      loader = "sg-0aaaaaaaaaaaaaaa1"
    }
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.client)) == toset(["loader"])
    error_message = "Without a proxy, only the loader reaches the cluster."
  }
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

run "no_client" {
  command = plan

  variables {
    client_security_group_ids = {}
  }

  expect_failures = [var.client_security_group_ids]
}

run "client_not_a_group" {
  command = plan

  variables {
    client_security_group_ids = {
      loader = "10.67.0.0/20"
    }
  }

  expect_failures = [var.client_security_group_ids]
}

run "instance_class_too_small" {
  command = plan

  variables {
    instance_class = "db.t4g.small"
  }

  expect_failures = [var.instance_class]
}

run "password_version_zero" {
  command = plan

  variables {
    password_version = 0
  }

  expect_failures = [var.password_version]
}

run "db_name_with_hyphen" {
  command = plan

  variables {
    db_name = "svp-lab"
  }

  expect_failures = [var.db_name]
}
