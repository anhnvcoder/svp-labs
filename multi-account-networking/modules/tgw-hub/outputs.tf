output "transit_gateway_id" {
  description = "ID of the transit gateway."
  value       = aws_ec2_transit_gateway.this.id
}

output "transit_gateway_arn" {
  description = "ARN of the transit gateway, the resource the RAM share gives to the spoke accounts."
  value       = aws_ec2_transit_gateway.this.arn
}

output "route_table_ids" {
  description = "ID of each route table of the transit gateway: prd, nonprd and egress."
  value       = { for k, t in aws_ec2_transit_gateway_route_table.this : k => t.id }
}
