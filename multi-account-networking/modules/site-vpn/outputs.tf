output "public_ip" {
  description = "Elastic IP of the customer gateway, for the router."
  value       = aws_eip.this.public_ip
}

output "eip_allocation_id" {
  description = "Allocation ID of that Elastic IP, for the router's interface."
  value       = aws_eip.this.allocation_id
}

output "vpn_connection_id" {
  description = "ID of the VPN connection, to read the status of its tunnels."
  value       = aws_vpn_connection.this.id
}

output "transit_gateway_attachment_id" {
  description = "ID of the VPN attachment of the transit gateway."
  value       = aws_vpn_connection.this.transit_gateway_attachment_id
}

output "preshared_key_arn" {
  description = "ARN of the Secrets Manager secret holding the keys of both tunnels; the ARN only, never a key."
  value       = aws_vpn_connection.this.preshared_key_arn
}

output "tunnels" {
  description = "Both tunnels in order: the AWS outside address and the customer gateway's inside address."
  value = [
    { outside_ip = aws_vpn_connection.this.tunnel1_address, cgw_inside_ip = aws_vpn_connection.this.tunnel1_cgw_inside_address },
    { outside_ip = aws_vpn_connection.this.tunnel2_address, cgw_inside_ip = aws_vpn_connection.this.tunnel2_cgw_inside_address },
  ]
}
