output "inbound_ips" {
  description = "Addresses of the inbound endpoint: the forwarders of the site's DNS server for the lab's zones."
  value       = local.addresses.inbound
}

output "rule_id" {
  description = "ID of the forwarding rule of the site's zone."
  value       = aws_route53_resolver_rule.site.id
}

output "outbound_ips" {
  description = "Addresses of the outbound endpoint, the sources of the queries the site's server receives."
  value       = local.addresses.outbound
}
