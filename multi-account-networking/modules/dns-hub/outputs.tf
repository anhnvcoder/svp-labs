output "profile_id" {
  description = "ID of the Route 53 Profile, which each spoke associates with its VPC."
  value       = aws_route53profiles_profile.this.id
}

output "profile_arn" {
  description = "ARN of the Route 53 Profile, the resource the RAM share gives to the spoke accounts."
  value       = aws_route53profiles_profile.this.arn
}

output "zone_ids" {
  description = "ID of each private hosted zone: net and nonprd."
  value       = { for k, z in aws_route53_zone.this : k => z.zone_id }
}

output "zone_names" {
  description = "Name of each private hosted zone: net and nonprd."
  value       = local.zones
}
