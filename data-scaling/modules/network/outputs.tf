output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "IPv4 range of the VPC; the loader may reach the data ports inside it."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_id" {
  description = "Subnet of the loader, routed to the internet gateway."
  value       = aws_subnet.public.id
}

output "data_subnet_ids" {
  description = "The two data subnets, in two availability zones, with no route out of the VPC: for a DB subnet group or an ElastiCache subnet group."
  value       = aws_subnet.data[*].id
}
