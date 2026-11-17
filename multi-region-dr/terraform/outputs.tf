output "primary_db_address" {
  description = "Host of the primary DB instance svp-lab-dr-primary in ap-southeast-1."
  value       = module.primary_db.address
}

output "dr_db_address" {
  description = "Host of the read replica svp-lab-dr-replica in us-east-1, the instance the drill promotes."
  value       = module.dr_db.address
}

output "replicated_backups_arn" {
  description = "ARN of the primary's automated backups replicated into us-east-1, the source of the point-in-time restore of the backup and restore path."
  value       = module.dr_db.replicated_backups_arn
}

output "bastion_ids" {
  description = "Instance IDs of the bastions, by Region; the drill finds them by their Name tag."
  value = {
    "ap-southeast-1" = module.primary_bastion.instance_id
    "us-east-1"      = module.dr_bastion.instance_id
  }
}

output "media_buckets" {
  description = "Source and destination of Cross-Region Replication."
  value = {
    source      = module.primary_media.name
    destination = module.dr_media.name
  }
}

output "db_record" {
  description = "Name the clients resolve; a failover pair of CNAME records in the private zone."
  value       = module.dns.record_name
}

output "failover_alarm" {
  description = "Alarm in us-east-1 behind the health check of the primary record: the failover switch."
  value       = module.dns.alarm_name
}

output "secret_name" {
  description = "Secret of the master password in ap-southeast-1, replicated to us-east-1 under the same name. The value is never an output."
  value       = module.db_secret.name
}
