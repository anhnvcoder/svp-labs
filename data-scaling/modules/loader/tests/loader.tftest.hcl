# Validation rules of the variables, then the protections of the loader: IMDSv2 with one hop, no inbound rule, egress
# limited to HTTPS and to the given data ports inside the VPC, a role that reads the given secrets only, an encrypted
# root volume. The AWS provider is a mock that returns the AMI below.

mock_provider "aws" {
  mock_data "aws_ssm_parameter" {
    defaults = {
      insecure_value = "ami-0123456789abcdef0"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
}

variables {
  name       = "svp-lab-ds-pg-loader"
  vpc_id     = "vpc-0123456789abcdef0"
  vpc_cidr   = "10.67.0.0/20"
  subnet_id  = "subnet-0aaaaaaaaaaaaaaa1"
  data_ports = [5432]
  secret_arns = [
    "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:svp-lab-ds-pg-master-AbCdEf",
  ]
  user_data = "#!/bin/bash\ntrue\n"
}

run "protections" {
  command = plan

  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required" && aws_instance.this.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "The instance accepts IMDSv2 only, with one hop."
  }

  assert {
    condition     = aws_instance.this.associate_public_ip_address && aws_instance.this.instance_type == "t4g.small" && aws_instance.this.credit_specification[0].cpu_credits == "unlimited"
    error_message = "The loader has a public address (no NAT gateway) and is a t4g.small in unlimited mode by default."
  }

  assert {
    condition     = aws_instance.this.user_data_replace_on_change && aws_instance.this.ami == "ami-0123456789abcdef0"
    error_message = "The AMI comes from the public SSM parameter, and a change of user data replaces the instance."
  }

  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted && aws_instance.this.root_block_device[0].volume_type == "gp3"
    error_message = "The root volume is an encrypted gp3."
  }

  assert {
    condition     = length(aws_security_group.this.ingress) == 0
    error_message = "The security group takes no inbound connection."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.https.from_port == 443 && aws_vpc_security_group_egress_rule.https.to_port == 443 && aws_vpc_security_group_egress_rule.https.cidr_ipv4 == "0.0.0.0/0"
    error_message = "HTTPS goes out to any address."
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_egress_rule.data)) == toset(["5432"]) && aws_vpc_security_group_egress_rule.data["5432"].from_port == 5432 && aws_vpc_security_group_egress_rule.data["5432"].to_port == 5432
    error_message = "One egress rule for PostgreSQL, port 5432 only."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.data["5432"].cidr_ipv4 == "10.67.0.0/20" && aws_vpc_security_group_egress_rule.data["5432"].ip_protocol == "tcp"
    error_message = "PostgreSQL goes out to the VPC only."
  }

  assert {
    condition     = tolist(jsondecode(aws_iam_role_policy.secret[0].policy).Statement[0].Resource) == var.secret_arns && jsondecode(aws_iam_role_policy.secret[0].policy).Statement[0].Action == "secretsmanager:GetSecretValue"
    error_message = "The role reads the secrets given and does nothing else with them."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.secret[0].policy).Statement) == 1
    error_message = "The secret policy holds one statement."
  }
}

run "two_secrets_two_ports" {
  command = plan

  variables {
    name       = "svp-lab-ds-kv-loader"
    vpc_cidr   = "10.67.16.0/20"
    data_ports = [6379, 5432, 6379]
    secret_arns = [
      "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:svp-lab-ds-kv-app-AbCdEf",
      "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:svp-lab-ds-kv-other-GhIjKl",
    ]
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_egress_rule.data)) == toset(["5432", "6379"]) && alltrue([for r in aws_vpc_security_group_egress_rule.data : r.cidr_ipv4 == "10.67.16.0/20" && r.from_port == r.to_port])
    error_message = "One egress rule per distinct data port, each to the VPC only and to that port only."
  }

  assert {
    condition     = tolist(jsondecode(aws_iam_role_policy.secret[0].policy).Statement[0].Resource) == var.secret_arns
    error_message = "The role reads exactly the two secrets given."
  }
}

run "no_secret_no_data_port" {
  command = plan

  variables {
    data_ports  = []
    secret_arns = []
  }

  assert {
    condition     = length(aws_iam_role_policy.secret) == 0
    error_message = "Without a secret there is no read policy, not a policy with an empty resource list."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.data) == 0
    error_message = "Without a data port there is no egress rule besides HTTPS."
  }
}

run "name_outside_the_lab" {
  command = plan

  variables {
    name = "svp-prd-loader"
  }

  expect_failures = [var.name]
}

run "instance_type_not_graviton" {
  command = plan

  variables {
    instance_type = "t3.small"
  }

  expect_failures = [var.instance_type]
}

run "vpc_id_not_an_id" {
  command = plan

  variables {
    vpc_id = "svp-lab-ds-pg"
  }

  expect_failures = [var.vpc_id]
}

run "vpc_cidr_not_a_range" {
  command = plan

  variables {
    vpc_cidr = "10.67.0.0"
  }

  expect_failures = [var.vpc_cidr]
}

run "subnet_id_given_a_vpc_id" {
  command = plan

  variables {
    subnet_id = "vpc-0123456789abcdef0"
  }

  expect_failures = [var.subnet_id]
}

run "secret_arn_of_another_service" {
  command = plan

  variables {
    secret_arns = ["arn:aws:ssm:ap-southeast-1:000000000000:parameter/svp-lab-ds"]
  }

  expect_failures = [var.secret_arns]
}

run "data_port_out_of_range" {
  command = plan

  variables {
    data_ports = [70000]
  }

  expect_failures = [var.data_ports]
}
