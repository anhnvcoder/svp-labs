output "service_name" {
  description = "Name of the endpoint service, which the consumer's interface endpoint connects to."
  value       = aws_vpc_endpoint_service.this.service_name

  # The consumer creates its endpoint from this name in one call, which fails until its account is allowed.
  depends_on = [aws_vpc_endpoint_service_allowed_principal.consumer]
}

output "service_id" {
  description = "ID of the endpoint service."
  value       = aws_vpc_endpoint_service.this.id
}
