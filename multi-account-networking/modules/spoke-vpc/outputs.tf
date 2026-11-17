output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "cidr" {
  description = "IPv4 range of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "workload_subnet_id" {
  description = "ID of the workload subnet, where the test instance runs."
  value       = aws_subnet.this["workload"].id
}

output "workload_subnet_arn" {
  description = "ARN of the workload subnet, the resource a RAM share gives to another account."
  value       = aws_subnet.this["workload"].arn
}

output "attachment_id" {
  description = "ID of the transit gateway attachment of the VPC."
  value       = aws_ec2_transit_gateway_vpc_attachment.this.id
}
