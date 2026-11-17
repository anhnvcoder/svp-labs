# The provider side of PrivateLink in prd, serving stg: one assertion per decision, then one plan per validation rule.
# The AWS provider is a mock: nothing reaches an account.

mock_provider "aws" {}

variables {
  name                  = "svp-lab-net-svc"
  vpc_id                = "vpc-0123456789abcdef0"
  subnet_id             = "subnet-0123456789abcdef0"
  instance_id           = "i-0123456789abcdef0"
  consumer_account_id   = "000000000000"
  accepted_endpoint_ids = { stg = "vpce-0123456789abcdef0" }
}

run "provider" {
  command = plan

  assert {
    condition     = aws_lb.this.internal == true && aws_lb.this.load_balancer_type == "network"
    error_message = "The service must sit behind an internal Network Load Balancer: nothing faces the internet."
  }

  assert {
    condition     = aws_vpc_endpoint_service.this.acceptance_required == true
    error_message = "Each connection request must wait for the provider's acceptance."
  }

  assert {
    condition     = aws_vpc_endpoint_service_allowed_principal.consumer.principal_arn == "arn:aws:iam::000000000000:root"
    error_message = "The consumer account alone may ask: one principal, never *."
  }

  assert {
    condition     = length(aws_vpc_endpoint_connection_accepter.this) == 1 && aws_vpc_endpoint_connection_accepter.this["stg"].vpc_endpoint_id == "vpce-0123456789abcdef0"
    error_message = "Only the named endpoint may be accepted."
  }

  assert {
    condition = (aws_lb_listener.this.port == 80 && aws_lb_listener.this.protocol == "TCP" &&
    aws_lb_target_group_attachment.this.target_id == "i-0123456789abcdef0")
    error_message = "The listener must forward TCP 80 to the test instance."
  }

  assert {
    condition = (aws_ssm_association.http.name == "AWS-RunShellScript" &&
      strcontains(aws_ssm_association.http.parameters["commands"], "DynamicUser=yes") &&
    aws_ssm_association.http.targets[0].values == tolist(["i-0123456789abcdef0"]))
    error_message = "The HTTP service must start on the test instance only, as an unprivileged user."
  }
}

run "consumer_not_account" {
  command = plan

  variables {
    consumer_account_id = "*"
  }

  expect_failures = [var.consumer_account_id]
}

run "accepted_not_endpoint" {
  command = plan

  variables {
    accepted_endpoint_ids = { stg = "vpc-0123456789abcdef0" }
  }

  expect_failures = [var.accepted_endpoint_ids]
}

run "instance_invalid" {
  command = plan

  variables {
    instance_id = "vpc-0123456789abcdef0"
  }

  expect_failures = [var.instance_id]
}

run "name_uppercase" {
  command = plan

  variables {
    name = "Svp-lab-net-svc"
  }

  expect_failures = [var.name]
}
