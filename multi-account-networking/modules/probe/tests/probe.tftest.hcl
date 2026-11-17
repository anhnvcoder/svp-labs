# The test instance of stg: one assertion per protection, then one plan per validation rule. The AWS provider is a
# mock: nothing reaches an account, and the AMI parameter returns the value below.

mock_provider "aws" {
  mock_data "aws_ssm_parameter" {
    defaults = {
      insecure_value = "ami-0123456789abcdef0"
    }
  }
}

variables {
  name      = "svp-lab-net-probe-stg"
  vpc_id    = "vpc-0123456789abcdef0"
  subnet_id = "subnet-0123456789abcdef0"
  lab_cidr  = "10.64.0.0/16"
}

run "probe" {
  command = plan

  assert {
    condition = (data.aws_ssm_parameter.ami.name == "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64" &&
    aws_instance.this.ami == "ami-0123456789abcdef0" && aws_instance.this.instance_type == "t4g.nano")
    error_message = "The probe must run the latest Amazon Linux 2023 arm64 on t4g.nano."
  }

  assert {
    condition = (aws_instance.this.metadata_options[0].http_tokens == "required" &&
      aws_instance.this.metadata_options[0].http_put_response_hop_limit == 1 &&
    aws_instance.this.metadata_options[0].http_endpoint == "enabled")
    error_message = "IMDSv2 only, hop limit 1."
  }

  assert {
    condition     = aws_instance.this.associate_public_ip_address == false
    error_message = "No public address: the probe is reached through Session Manager only."
  }

  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted == true
    error_message = "The root volume must be encrypted."
  }

  assert {
    condition = alltrue([for r in aws_vpc_security_group_ingress_rule.this :
      r.cidr_ipv4 == "10.64.0.0/16" && (r.ip_protocol == "icmp" || (r.ip_protocol == "tcp" && r.from_port == 80 && r.to_port == 80))
    ])
    error_message = "Ingress must be only ping and TCP 80 from the lab: no SSH, nothing from outside the lab."
  }

  assert {
    condition = (aws_vpc_security_group_egress_rule.https.ip_protocol == "tcp" &&
      aws_vpc_security_group_egress_rule.https.from_port == 443 && aws_vpc_security_group_egress_rule.https.to_port == 443 &&
    aws_vpc_security_group_egress_rule.lab.cidr_ipv4 == "10.64.0.0/16")
    error_message = "Egress must be HTTPS anywhere and any traffic inside the lab, nothing else."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.ssm_core.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    error_message = "The role must hold the SSM agent policy."
  }

  assert {
    condition = jsondecode(aws_iam_role.this.assume_role_policy).Statement == [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
    error_message = "Only EC2 may assume the role."
  }

  assert {
    condition     = aws_instance.this.tags["Name"] == "svp-lab-net-probe-stg" && aws_iam_role.this.name == "svp-lab-net-probe-stg"
    error_message = "Names must follow svp-lab-net-probe-<vpc>."
  }
}

run "lab_cidr_everything" {
  command = plan

  variables {
    lab_cidr = "0.0.0.0/0"
  }

  expect_failures = [var.lab_cidr]
}

run "vpc_id_invalid" {
  command = plan

  variables {
    vpc_id = "subnet-0123456789abcdef0"
  }

  expect_failures = [var.vpc_id]
}

run "subnet_id_invalid" {
  command = plan

  variables {
    subnet_id = "vpc-0123456789abcdef0"
  }

  expect_failures = [var.subnet_id]
}

run "name_uppercase" {
  command = plan

  variables {
    name = "Svp-lab-net-probe"
  }

  expect_failures = [var.name]
}
