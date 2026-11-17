output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "IPv4 range of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "subnet_ids" {
  description = "Subnets of the VPC, the first one in the first availability zone: one public subnet, or two private ones."
  value       = aws_subnet.this[*].id
}

output "subnet_cidrs" {
  description = "IPv4 ranges of the subnets, in the order of subnet_ids."
  value       = aws_subnet.this[*].cidr_block
}

output "availability_zone" {
  description = "Availability zone of the first subnet, where the lab places every instance so that no byte crosses zones."
  value       = aws_subnet.this[0].availability_zone
}

output "route_table_id" {
  description = "Route table of the subnets, where the peering module adds the route to the other VPC."
  value       = aws_route_table.this.id
}
