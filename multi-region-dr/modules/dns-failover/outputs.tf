output "zone_id" {
  description = "ID of the private hosted zone."
  value       = aws_route53_zone.this.zone_id
}

output "record_name" {
  description = "The name clients resolve, db.<zone_name>."
  value       = aws_route53_record.primary.name
}

output "alarm_name" {
  description = "Name of the alarm behind the health check of the primary record, the failover switch."
  value       = aws_cloudwatch_metric_alarm.failover.alarm_name
}
