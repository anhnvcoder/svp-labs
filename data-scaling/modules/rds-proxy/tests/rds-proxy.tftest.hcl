# Validation rules of the variables, then the proxy the lab measures: TLS required, the part's secret as its only
# credential, a role that reads that secret alone, 5432 in from the loader and out to the Aurora cluster's group and
# nowhere else. The AWS provider is a mock that returns the key below.

mock_provider "aws" {
  mock_data "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:ap-southeast-1:000000000000:key/00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  name                     = "svp-lab-ds-proxy"
  vpc_id                   = "vpc-0123456789abcdef0"
  subnet_ids               = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
  client_security_group_id = "sg-0aaaaaaaaaaaaaaa1"
  target_security_group_id = "sg-0ccccccccccccccc3"
  cluster_identifier       = "svp-lab-ds-aurora"
  secret_arn               = "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:svp-lab-ds-pg-master-AbCdEf"
}

run "proxy" {
  command = plan

  assert {
    condition     = aws_db_proxy.this.name == "svp-lab-ds-proxy" && aws_db_proxy.this.engine_family == "POSTGRESQL" && aws_db_proxy.this.require_tls
    error_message = "The proxy speaks PostgreSQL and refuses clients without TLS."
  }

  assert {
    condition     = [for a in aws_db_proxy.this.auth : a.secret_arn] == [var.secret_arn] && alltrue([for a in aws_db_proxy.this.auth : a.auth_scheme == "SECRETS" && a.iam_auth == "DISABLED" && a.client_password_auth_type == "POSTGRES_SCRAM_SHA_256"])
    error_message = "The proxy logs in with the part's secret alone; clients authenticate with SCRAM."
  }

  assert {
    condition     = aws_db_proxy_target.this.db_cluster_identifier == "svp-lab-ds-aurora" && aws_db_proxy_target.this.db_instance_identifier == null
    error_message = "The proxy fronts the Aurora cluster."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.secret.policy).Statement) == 2
    error_message = "The role's policy has two statements: read the secret, decrypt it."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.secret.policy).Statement[0].Action == "secretsmanager:GetSecretValue" && jsondecode(aws_iam_role_policy.secret.policy).Statement[0].Resource == var.secret_arn
    error_message = "The role reads the part's secret and no other."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.secret.policy).Statement[1].Action == "kms:Decrypt" && jsondecode(aws_iam_role_policy.secret.policy).Statement[1].Resource == "arn:aws:kms:ap-southeast-1:000000000000:key/00000000-0000-0000-0000-000000000000"
    error_message = "The role decrypts with the AWS managed key of Secrets Manager only."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.secret.policy).Statement[1].Condition.StringEquals["kms:ViaService"] == "secretsmanager.ap-southeast-1.amazonaws.com"
    error_message = "The key is usable only through Secrets Manager of the secret's Region."
  }

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Principal.Service == "rds.amazonaws.com"
    error_message = "Only RDS assumes the proxy's role."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.target.referenced_security_group_id == "sg-0ccccccccccccccc3" && aws_vpc_security_group_egress_rule.target.cidr_ipv4 == null && aws_vpc_security_group_egress_rule.target.cidr_ipv6 == null && aws_vpc_security_group_egress_rule.target.prefix_list_id == null
    error_message = "The proxy's only egress goes to the Aurora cluster's security group, never to an address range."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.target.from_port == 5432 && aws_vpc_security_group_egress_rule.target.to_port == 5432 && aws_vpc_security_group_egress_rule.target.ip_protocol == "tcp"
    error_message = "The proxy's egress is 5432 only."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.client.referenced_security_group_id == "sg-0aaaaaaaaaaaaaaa1" && aws_vpc_security_group_ingress_rule.client.from_port == 5432 && aws_vpc_security_group_ingress_rule.client.to_port == 5432 && aws_vpc_security_group_ingress_rule.client.cidr_ipv4 == null
    error_message = "Only the loader reaches the proxy, on 5432."
  }
}

run "name_outside_the_lab" {
  command = plan

  variables {
    name = "svp-prd-proxy"
  }

  expect_failures = [var.name]
}

run "secret_arn_not_a_secret" {
  command = plan

  variables {
    secret_arn = "arn:aws:ssm:ap-southeast-1:000000000000:parameter/svp-lab-ds-pg-master"
  }

  expect_failures = [var.secret_arn]
}

run "target_not_a_group" {
  command = plan

  variables {
    target_security_group_id = "10.67.0.0/20"
  }

  expect_failures = [var.target_security_group_id]
}

run "subnet_ids_one_zone" {
  command = plan

  variables {
    subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1"]
  }

  expect_failures = [var.subnet_ids]
}

run "cluster_outside_the_lab" {
  command = plan

  variables {
    cluster_identifier = "svp-prd"
  }

  expect_failures = [var.cluster_identifier]
}
