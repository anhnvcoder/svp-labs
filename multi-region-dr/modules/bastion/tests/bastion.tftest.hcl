# Validation rules of the variables, then the protections of the bastion: IMDSv2 with one hop, no inbound rule,
# egress limited to HTTPS and to PostgreSQL inside the VPC, and a role that reads one secret only. The AWS provider is a
# mock that returns the AMI below.

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
  name       = "svp-lab-dr-bastion-dr"
  vpc_id     = "vpc-0123456789abcdef0"
  vpc_cidr   = "10.65.16.0/20"
  subnet_id  = "subnet-0aaaaaaaaaaaaaaa1"
  secret_arn = "arn:aws:secretsmanager:us-east-1:000000000000:secret:svp-lab-dr-db-master-AbCdEf"
  user_data  = "#!/bin/bash\ntrue\n"
}

run "protections" {
  command = plan

  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required" && aws_instance.this.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "The instance accepts IMDSv2 only, with one hop."
  }

  assert {
    condition     = aws_instance.this.associate_public_ip_address && aws_instance.this.instance_type == "t4g.micro"
    error_message = "The bastion has a public address (no NAT gateway) and is a t4g.micro by default."
  }

  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted && aws_instance.this.root_block_device[0].volume_size == 8
    error_message = "The root volume is encrypted, 8 GiB."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.postgres.cidr_ipv4 == "10.65.16.0/20" && aws_vpc_security_group_egress_rule.postgres.from_port == 5432
    error_message = "PostgreSQL goes out to the VPC only."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.secret.policy).Statement[0].Resource == var.secret_arn && jsondecode(aws_iam_role_policy.secret.policy).Statement[0].Action == "secretsmanager:GetSecretValue"
    error_message = "The role reads the one secret of its Region and does nothing else with it."
  }
}

run "name_outside_the_lab" {
  command = plan

  variables {
    name = "svp-prd-bastion"
  }

  expect_failures = [var.name]
}

run "instance_type_not_graviton" {
  command = plan

  variables {
    instance_type = "t3.micro"
  }

  expect_failures = [var.instance_type]
}

run "vpc_id_not_an_id" {
  command = plan

  variables {
    vpc_id = "svp-lab-dr"
  }

  expect_failures = [var.vpc_id]
}

run "vpc_cidr_not_a_range" {
  command = plan

  variables {
    vpc_cidr = "10.65.16.0"
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
    secret_arn = "arn:aws:ssm:us-east-1:000000000000:parameter/svp-lab-dr"
  }

  expect_failures = [var.secret_arn]
}
