output "probes" {
  description = "Each test instance: the account key that owns it (network, stg or prd), its ID for Session Manager, its ARN for Reachability Analyzer and its private address."
  value = {
    egress = { account = "network", instance_id = module.probe_egress.instance_id, instance_arn = module.probe_egress.instance_arn, private_ip = module.probe_egress.private_ip }
    shared = { account = "stg", instance_id = module.probe_shared.instance_id, instance_arn = module.probe_shared.instance_arn, private_ip = module.probe_shared.private_ip }
    stg    = { account = "stg", instance_id = module.probe_stg.instance_id, instance_arn = module.probe_stg.instance_arn, private_ip = module.probe_stg.private_ip }
    prd    = { account = "prd", instance_id = module.probe_prd.instance_id, instance_arn = module.probe_prd.instance_arn, private_ip = module.probe_prd.private_ip }
  }
}

output "internet_gateway_arn" {
  description = "ARN of the internet gateway of the egress VPC, the destination of the Reachability Analyzer paths to the internet."
  value       = module.egress.internet_gateway_arn
}

output "nat_public_ip" {
  description = "Public IPv4 address of the NAT gateway, which a site on the internet sees for every VPC of the lab."
  value       = module.egress.nat_public_ip
}

output "transit_gateway_id" {
  description = "ID of the transit gateway in svp-network."
  value       = module.hub.transit_gateway_id
}

output "transit_gateway_route_table_ids" {
  description = "ID of each route table of the transit gateway: prd, nonprd and egress."
  value       = module.hub.route_table_ids
}

output "dns_profile_id" {
  description = "ID of the Route 53 Profile svp-lab-net."
  value       = module.dns_hub.profile_id
}
