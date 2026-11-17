output "router_private_ip" {
  description = "Private address of the router: the site's DNS server and the target of the lab's Resolver rule."
  value       = local.router_ip
}

output "router_instance_id" {
  description = "ID of the router instance, the target of a Session Manager session."
  value       = aws_instance.router.id
}

output "host_private_ip" {
  description = "Private address of the host behind the router."
  value       = local.host_ip
}

output "host_instance_id" {
  description = "ID of the host instance, the target of a Session Manager session."
  value       = aws_instance.host.id
}

output "host_instance_arn" {
  description = "ARN of the host instance: Reachability Analyzer names a resource of another account by ARN."
  value       = aws_instance.host.arn
}
