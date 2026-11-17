output "endpoint_id" {
  description = "ID of the interface endpoint, which the provider accepts."
  value       = aws_vpc_endpoint.this.id
}

output "dns_name" {
  description = "Regional DNS name of the endpoint, the name a client of the consumer VPC calls."
  value       = aws_vpc_endpoint.this.dns_entry[0].dns_name
}
