# The name the clients of both Regions use, db.<zone>, in a private hosted zone: a failover pair of CNAME records whose
# primary carries a health check on a CloudWatch alarm, since Route 53 health checkers cannot reach an endpoint inside a
# VPC. The alarm is the failover switch of the drill, kept in the DR Region, which survives the loss of the primary.
# Design notes: multi-region-dr/README.md.

data "aws_region" "current" {}

# force_destroy: the drill points the secondary record at a restored instance outside Terraform.
resource "aws_route53_zone" "this" {
  name          = var.zone_name
  comment       = "Private zone of the multi-region-dr lab"
  force_destroy = true

  dynamic "vpc" {
    for_each = var.vpcs

    content {
      vpc_id     = vpc.value.vpc_id
      vpc_region = vpc.value.region
    }
  }
}

# The failover switch: the drill writes FailoverRequested = 1. Route 53 judges the health check on this alarm's data
# stream and criteria without waiting for the ALARM state, and supports only standard-resolution alarms with a plain
# statistic, one datapoint out of one. Missing data keeps the alarm's own state; LastKnownStatus keeps the check's.
resource "aws_cloudwatch_metric_alarm" "failover" {
  alarm_name          = "${var.name}-failover"
  alarm_description   = "Failover switch of the multi-region-dr lab: a 1 sends db.${var.zone_name} to the DR instance."
  namespace           = var.name
  metric_name         = "FailoverRequested"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "ignore"
}

# LastKnownStatus: once the switch is down, Route 53 keeps it down after the last datapoint ages out; a new health check
# with no known status counts as healthy.
resource "aws_route53_health_check" "primary" {
  type                            = "CLOUDWATCH_METRIC"
  cloudwatch_alarm_name           = aws_cloudwatch_metric_alarm.failover.alarm_name
  cloudwatch_alarm_region         = data.aws_region.current.region
  insufficient_data_health_status = "LastKnownStatus"

  tags = {
    Name = "${var.name}-primary"
  }
}

resource "aws_route53_record" "primary" {
  zone_id         = aws_route53_zone.this.zone_id
  name            = "db.${var.zone_name}"
  type            = "CNAME"
  ttl             = var.ttl
  records         = [var.primary_target]
  set_identifier  = "primary"
  health_check_id = aws_route53_health_check.primary.id

  failover_routing_policy {
    type = "PRIMARY"
  }
}

resource "aws_route53_record" "secondary" {
  zone_id        = aws_route53_zone.this.zone_id
  name           = "db.${var.zone_name}"
  type           = "CNAME"
  ttl            = var.ttl
  records        = [var.secondary_target]
  set_identifier = "secondary"

  failover_routing_policy {
    type = "SECONDARY"
  }
}
