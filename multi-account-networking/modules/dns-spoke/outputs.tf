output "profile_association_id" {
  description = "ID of the association of the Profile with the VPC."
  value       = aws_route53profiles_association.this.id
}
