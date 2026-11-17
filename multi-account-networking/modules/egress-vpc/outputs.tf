output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "cidr" {
  description = "IPv4 range of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "probe_subnet_id" {
  description = "ID of the subnet of the test instance."
  value       = aws_subnet.this["probe"].id
}

output "attachment_id" {
  description = "ID of the transit gateway attachment of the VPC."
  value       = aws_ec2_transit_gateway_vpc_attachment.this.id
}

output "internet_gateway_arn" {
  description = "ARN of the internet gateway, the destination of the Reachability Analyzer paths to the internet."
  value       = aws_internet_gateway.this.arn
}

output "nat_public_ip" {
  description = "Public IPv4 address of the NAT gateway: what a site on the internet sees for every VPC of the lab."
  value       = aws_eip.nat.public_ip
}
