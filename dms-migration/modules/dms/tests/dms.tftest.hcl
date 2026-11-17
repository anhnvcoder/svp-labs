# Validation rules of the variables, then the DMS setup the lab relies on: a private instance on an engine that
# validates uuid keys, endpoints that read Secrets Manager through the VPC endpoint (TLS require on the source,
# verify-full on the target), a stopped task with validation and logging, and the account-wide roles only on request.
# The AWS provider is a mock that returns the Region and partition below.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
}

variables {
  name              = "svp-lab-dms"
  vpc_id            = "vpc-0123456789abcdef0"
  subnet_ids        = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
  availability_zone = "ap-southeast-1a"
  source_cidrs      = ["192.168.16.0/24"]
  target_cidr       = "10.66.0.0/20"
  source_secret_arn = "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:svp-lab-dms-source-AbCdEf"
  target_secret_arn = "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:svp-lab-dms-target-GhIjKl"
  rds_ca_bundle     = "-----BEGIN CERTIFICATE-----\nTESTONLY\n-----END CERTIFICATE-----\n"
}

run "instance" {
  command = plan

  assert {
    condition     = !aws_dms_replication_instance.this.publicly_accessible && !aws_dms_replication_instance.this.multi_az && aws_dms_replication_instance.this.availability_zone == "ap-southeast-1a"
    error_message = "The replication instance is private and Single-AZ, in the zone of source and target."
  }

  assert {
    condition     = aws_dms_replication_instance.this.engine_version == "3.6.1" && aws_dms_replication_instance.this.auto_minor_version_upgrade && aws_dms_replication_instance.this.replication_instance_class == "dms.t3.micro"
    error_message = "The engine is 3.6.1 with automatic minor upgrades, on dms.t3.micro."
  }

  assert {
    condition     = aws_vpc_endpoint.secretsmanager.service_name == "com.amazonaws.ap-southeast-1.secretsmanager" && aws_vpc_endpoint.secretsmanager.subnet_ids == toset(["subnet-0aaaaaaaaaaaaaaa1"]) && aws_vpc_endpoint.secretsmanager.private_dns_enabled
    error_message = "Secrets Manager is reached through one interface endpoint in the zone of the instance."
  }

  assert {
    condition     = [for r in aws_vpc_security_group_egress_rule.source : r.cidr_ipv4] == ["192.168.16.0/24"] && aws_vpc_security_group_egress_rule.target.cidr_ipv4 == "10.66.0.0/20" && aws_vpc_security_group_egress_rule.target.from_port == 5432
    error_message = "DMS opens PostgreSQL connections to the source subnet and the AWS-side VPC only."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.secrets.from_port == 443 && aws_vpc_security_group_ingress_rule.endpoint.from_port == 443
    error_message = "DMS reaches the endpoint on HTTPS, and the endpoint lets in DMS only."
  }

  assert {
    condition     = length(aws_iam_role.vpc) == 1 && aws_iam_role.vpc[0].name == "dms-vpc-role" && aws_iam_role.logs[0].name == "dms-cloudwatch-logs-role"
    error_message = "By default the lab creates the two account-wide roles under the names DMS looks up."
  }

  assert {
    condition     = jsondecode(aws_iam_role.secrets.assume_role_policy).Statement[0].Principal.Service == "dms.ap-southeast-1.amazonaws.com"
    error_message = "The secrets role trusts the regional DMS service principal."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.secrets.policy).Statement[0].Action == "secretsmanager:GetSecretValue" && jsondecode(aws_iam_role_policy.secrets.policy).Statement[0].Resource == [var.source_secret_arn, var.target_secret_arn]
    error_message = "DMS reads the two endpoint secrets and nothing else."
  }
}

run "endpoints" {
  command = plan

  assert {
    condition     = aws_dms_endpoint.source.ssl_mode == "require" && aws_dms_endpoint.target.ssl_mode == "verify-full"
    error_message = "The source connection is encrypted; the target one also checks the certificate and host name."
  }

  assert {
    condition     = aws_dms_endpoint.source.secrets_manager_arn == var.source_secret_arn && aws_dms_endpoint.target.secrets_manager_arn == var.target_secret_arn
    error_message = "Each endpoint reads its own secret."
  }

  assert {
    condition     = aws_dms_endpoint.source.username == null && aws_dms_endpoint.source.password == null && aws_dms_endpoint.target.password == null && aws_dms_endpoint.target.server_name == null
    error_message = "No credential or host goes into the endpoints, so the state holds none."
  }

  assert {
    condition     = aws_dms_endpoint.source.postgres_settings[0].capture_ddls == false && aws_dms_endpoint.source.postgres_settings[0].plugin_name == "test-decoding"
    error_message = "The source leaves DDL capture off and decodes with test_decoding from the contrib package."
  }

  assert {
    condition     = aws_dms_certificate.rds.certificate_pem == var.rds_ca_bundle
    error_message = "The target is verified against the RDS bundle given."
  }
}

run "task" {
  command = plan

  assert {
    condition     = aws_dms_replication_task.this.migration_type == "full-load-and-cdc" && aws_dms_replication_task.this.start_replication_task == false
    error_message = "The task runs full load then CDC, and Terraform leaves it stopped."
  }

  assert {
    condition     = jsondecode(aws_dms_replication_task.this.replication_task_settings).ValidationSettings.EnableValidation && jsondecode(aws_dms_replication_task.this.replication_task_settings).FullLoadSettings.TargetTablePrepMode == "TRUNCATE_BEFORE_LOAD"
    error_message = "Validation is on and the full load keeps the tables created beforehand."
  }

  assert {
    condition     = sort([for c in jsondecode(aws_dms_replication_task.this.replication_task_settings).Logging.LogComponents : c.Id]) == tolist(["SOURCE_CAPTURE", "SOURCE_UNLOAD", "TARGET_APPLY", "TARGET_LOAD"])
    error_message = "Logging covers the source and target components that Security Hub checks."
  }

  assert {
    condition     = [for r in jsondecode(aws_dms_replication_task.this.table_mappings).rules : r["object-locator"]["table-name"]] == ["view_counts", "likes", "heartbeat"]
    error_message = "The task selects the three tables by name."
  }

  assert {
    condition     = aws_cloudwatch_log_group.task.name == "dms-tasks-svp-lab-dms" && aws_cloudwatch_log_group.task.retention_in_days == 1
    error_message = "The task logs go to the group DMS names after the instance, kept one day."
  }
}

run "existing_vpc_role" {
  command = plan

  variables {
    create_vpc_role = false
  }

  assert {
    condition     = length(aws_iam_role.vpc) == 0 && length(aws_iam_role_policy_attachment.vpc) == 0 && length(aws_iam_role.logs) == 1
    error_message = "With dms-vpc-role already in the account, the lab neither creates nor deletes it, and still creates the other."
  }
}

run "existing_logs_role" {
  command = plan

  variables {
    create_logs_role = false
  }

  assert {
    condition     = length(aws_iam_role.logs) == 0 && length(aws_iam_role_policy_attachment.logs) == 0 && length(aws_iam_role.vpc) == 1
    error_message = "With dms-cloudwatch-logs-role already in the account, the lab neither creates nor deletes it, and still creates the other."
  }
}

run "engine_before_uuid_validation" {
  command = plan

  variables {
    engine_version = "3.5.4"
  }

  expect_failures = [var.engine_version]
}

run "instance_class_too_large" {
  command = plan

  variables {
    instance_class = "dms.r6i.large"
  }

  expect_failures = [var.instance_class]
}

run "rds_ca_bundle_not_pem" {
  command = plan

  variables {
    rds_ca_bundle = "global-bundle.pem"
  }

  expect_failures = [var.rds_ca_bundle]
}

run "source_cidrs_open_to_all" {
  command = plan

  variables {
    source_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.source_cidrs]
}

run "subnet_ids_one_zone" {
  command = plan

  variables {
    subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1"]
  }

  expect_failures = [var.subnet_ids]
}

run "table_with_uppercase" {
  command = plan

  variables {
    tables = ["ViewCounts"]
  }

  expect_failures = [var.tables]
}

run "name_outside_the_lab" {
  command = plan

  variables {
    name = "svp-prd"
  }

  expect_failures = [var.name]
}
