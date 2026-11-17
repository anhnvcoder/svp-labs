# Validation rules of the variables, then the protections of the on-premises stand-in: IMDSv2 with one hop, encrypted
# disk, 5432 open to the DMS subnets only, a write-only password parameter, and a role that reads one parameter, one
# secret and the statistics of one task. The AWS provider is a mock that returns the AMI and Region below.

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

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "000000000000"
    }
  }
}

variables {
  name                    = "svp-lab-dms-source"
  vpc_id                  = "vpc-0123456789abcdef0"
  subnet_id               = "subnet-0aaaaaaaaaaaaaaa1"
  dms_cidrs               = ["10.66.0.0/24", "10.66.1.0/24"]
  target_cidr             = "10.66.0.0/20"
  password_parameter_name = "/svp-lab-dms/source/svp_dms-password"
  password                = "test-only-not-a-secret"
  password_version        = 1
  target_secret_arn       = "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:svp-lab-dms-target-AbCdEf"
  task_arn                = "arn:aws:dms:ap-southeast-1:000000000000:task:ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  user_data               = "#!/bin/bash\ntrue\n"
}

run "protections" {
  command = plan

  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required" && aws_instance.this.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "The instance accepts IMDSv2 only, with one hop."
  }

  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted && aws_instance.this.associate_public_ip_address && aws_instance.this.instance_type == "t4g.micro"
    error_message = "The disk is encrypted, the instance has a public address (no NAT gateway) and is a t4g.micro."
  }

  assert {
    condition     = sort([for r in aws_vpc_security_group_ingress_rule.dms : "${r.cidr_ipv4}:${r.from_port}-${r.to_port}"]) == tolist(["10.66.0.0/24:5432-5432", "10.66.1.0/24:5432-5432"])
    error_message = "Only the DMS subnets reach the instance, on 5432 only."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.target.cidr_ipv4 == "10.66.0.0/20" && aws_vpc_security_group_egress_rule.target.from_port == 5432
    error_message = "PostgreSQL goes out to the AWS side only."
  }

  assert {
    condition     = aws_ssm_parameter.password.type == "SecureString" && aws_ssm_parameter.password.value_wo_version == 1
    error_message = "The password is a SecureString written through value_wo."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.password.policy).Statement[0].Resource == "arn:aws:ssm:ap-southeast-1:000000000000:parameter/svp-lab-dms/source/svp_dms-password"
    error_message = "The instance reads the one password parameter."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.password.policy).Statement[1].Condition.StringEquals == { "kms:ViaService" = "ssm.ap-southeast-1.amazonaws.com", "kms:EncryptionContext:PARAMETER_ARN" = "arn:aws:ssm:ap-southeast-1:000000000000:parameter/svp-lab-dms/source/svp_dms-password" }
    error_message = "The instance decrypts only through Parameter Store, and only that parameter."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.cutover.policy).Statement[0].Resource == var.target_secret_arn && jsondecode(aws_iam_role_policy.cutover.policy).Statement[1].Resource == var.task_arn
    error_message = "The cutover reads the one target secret and acts on the one task."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.cutover.policy).Statement[1].Action == ["dms:DescribeTableStatistics", "dms:StopReplicationTask"]
    error_message = "The cutover reads the validation statistics and stops the task, nothing more."
  }
}

run "dms_cidrs_open_to_all" {
  command = plan

  variables {
    dms_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.dms_cidrs]
}

run "dms_cidrs_empty" {
  command = plan

  variables {
    dms_cidrs = []
  }

  expect_failures = [var.dms_cidrs]
}

run "instance_type_not_graviton" {
  command = plan

  variables {
    instance_type = "t3.micro"
  }

  expect_failures = [var.instance_type]
}

run "parameter_outside_the_lab" {
  command = plan

  variables {
    password_parameter_name = "/svp/prd/db-password"
  }

  expect_failures = [var.password_parameter_name]
}

run "task_arn_of_an_endpoint" {
  command = plan

  variables {
    task_arn = "arn:aws:dms:ap-southeast-1:000000000000:endpoint:ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  }

  expect_failures = [var.task_arn]
}

run "name_outside_the_lab" {
  command = plan

  variables {
    name = "svp-prd-db"
  }

  expect_failures = [var.name]
}
