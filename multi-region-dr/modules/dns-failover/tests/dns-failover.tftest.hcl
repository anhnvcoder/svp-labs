# Validation rules of the variables, then the failover the drill flips: a zone in both VPCs, a primary record behind a
# health check on the switch alarm, and an alarm Route 53 accepts (standard resolution, plain statistic, one datapoint).
# The AWS provider is a mock whose Region is the DR Region.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }
}

variables {
  name = "svp-lab-dr"
  vpcs = [
    { vpc_id = "vpc-0aaaaaaaaaaaaaaa1", region = "ap-southeast-1" },
    { vpc_id = "vpc-0bbbbbbbbbbbbbbb2", region = "us-east-1" },
  ]
  primary_target   = "svp-lab-dr-primary.abcdefghijkl.ap-southeast-1.rds.amazonaws.com"
  secondary_target = "svp-lab-dr-replica.abcdefghijkl.us-east-1.rds.amazonaws.com"
}

run "failover" {
  command = plan

  assert {
    condition     = toset([for v in aws_route53_zone.this.vpc : "${v.vpc_id}@${v.vpc_region}"]) == toset(["vpc-0aaaaaaaaaaaaaaa1@ap-southeast-1", "vpc-0bbbbbbbbbbbbbbb2@us-east-1"])
    error_message = "The zone answers in the VPC of each Region."
  }

  assert {
    condition     = aws_route53_record.primary.name == "db.svp-lab-dr.internal" && aws_route53_record.primary.records == toset([var.primary_target]) && aws_route53_record.primary.failover_routing_policy[0].type == "PRIMARY"
    error_message = "db.<zone> answers the primary instance first."
  }

  assert {
    condition     = aws_route53_record.secondary.records == toset([var.secondary_target]) && aws_route53_record.secondary.failover_routing_policy[0].type == "SECONDARY" && aws_route53_record.secondary.health_check_id == null
    error_message = "The DR instance answers when the primary is unhealthy; the secondary has no health check."
  }

  assert {
    condition     = aws_route53_record.primary.ttl == 10 && aws_route53_record.secondary.ttl == 10
    error_message = "Both records carry the TTL the RTO includes."
  }

  assert {
    condition     = aws_route53_health_check.primary.type == "CLOUDWATCH_METRIC" && aws_route53_health_check.primary.cloudwatch_alarm_region == "us-east-1" && aws_route53_health_check.primary.insufficient_data_health_status == "LastKnownStatus"
    error_message = "The health check follows the switch alarm of the DR Region and keeps its last status without data."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.failover.period == 60 && aws_cloudwatch_metric_alarm.failover.statistic == "Maximum" && aws_cloudwatch_metric_alarm.failover.datapoints_to_alarm == aws_cloudwatch_metric_alarm.failover.evaluation_periods
    error_message = "Route 53 accepts only a standard-resolution alarm with a plain statistic and no M out of N."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.failover.namespace == "svp-lab-dr" && aws_cloudwatch_metric_alarm.failover.metric_name == "FailoverRequested" && aws_cloudwatch_metric_alarm.failover.treat_missing_data == "ignore"
    error_message = "The drill writes svp-lab-dr/FailoverRequested; missing data keeps the switch where it is."
  }
}

run "name_other_than_the_lab" {
  command = plan

  variables {
    name = "svp-lab-dms"
  }

  expect_failures = [var.name]
}

run "zone_name_single_label" {
  command = plan

  variables {
    zone_name = "internal"
  }

  expect_failures = [var.zone_name]
}

run "vpc_in_another_region" {
  command = plan

  variables {
    vpcs = [{ vpc_id = "vpc-0aaaaaaaaaaaaaaa1", region = "xx-nowhere-1" }]
  }

  expect_failures = [var.vpcs]
}

run "no_vpc" {
  command = plan

  variables {
    vpcs = []
  }

  expect_failures = [var.vpcs]
}

run "ttl_zero" {
  command = plan

  variables {
    ttl = 0
  }

  expect_failures = [var.ttl]
}

run "primary_target_with_scheme" {
  command = plan

  variables {
    primary_target = "postgres://svp-lab-dr-primary"
  }

  expect_failures = [var.primary_target]
}

run "secondary_target_with_port" {
  command = plan

  variables {
    secondary_target = "svp-lab-dr-replica:5432"
  }

  expect_failures = [var.secondary_target]
}
