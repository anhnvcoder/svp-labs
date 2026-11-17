output "network_account_id" {
  description = "ID of the account svp-network: export it as SVP_AWS_NETWORK_ACCOUNT_ID for the root core."
  value       = aws_organizations_account.network.id
}

output "infrastructure_ou_id" {
  description = "ID of the OU Infrastructure that holds the account."
  value       = aws_organizations_organizational_unit.infrastructure.id
}
