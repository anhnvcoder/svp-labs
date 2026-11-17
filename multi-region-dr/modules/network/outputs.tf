output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "IPv4 range of the VPC; the bastion may reach PostgreSQL inside it."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_id" {
  description = "Subnet of the bastion, routed to the internet gateway."
  value       = aws_subnet.public.id
}

output "db_subnet_ids" {
  description = "The two database subnets, in two availability zones, with no route out of the VPC."
  value       = aws_subnet.db[*].id
}
