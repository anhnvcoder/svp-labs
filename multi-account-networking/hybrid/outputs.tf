output "site" {
  description = "The simulated site: instance ID of the router and of the host for Session Manager, their private addresses, and the host's ARN for Reachability Analyzer."
  value = {
    router = { instance_id = module.site.router_instance_id, private_ip = module.site.router_private_ip }
    host   = { instance_id = module.site.host_instance_id, instance_arn = module.site.host_instance_arn, private_ip = module.site.host_private_ip }
  }
}

output "vpn_connection_id" {
  description = "ID of the Site-to-Site VPN connection, whose tunnel status the session reads."
  value       = module.vpn.vpn_connection_id
}

output "resolver_ips" {
  description = "Addresses of the inbound and outbound Resolver endpoints."
  value       = { inbound = module.resolver.inbound_ips, outbound = module.resolver.outbound_ips }
}

output "service_dns_name" {
  description = "Regional DNS name of the interface endpoint in stg, through which stg calls the service of prd."
  value       = module.service_stg.dns_name
}
