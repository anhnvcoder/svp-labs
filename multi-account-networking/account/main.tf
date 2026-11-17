data "aws_organizations_organization" "this" {}

# The OU of the AWS Security Reference Architecture for shared infrastructure such as networking. Managed here only:
# the Terraform of the organization in svp-infra does not know it.
resource "aws_organizations_organizational_unit" "infrastructure" {
  name      = "Infrastructure"
  parent_id = data.aws_organizations_organization.this.roots[0].id
}

# Lives across the lab's sessions. Closing it is a manual step of the README, so a destroy can never close it.
resource "aws_organizations_account" "network" {
  name      = "svp-network"
  email     = var.network_account_email
  parent_id = aws_organizations_organizational_unit.infrastructure.id

  close_on_deletion = false

  lifecycle {
    prevent_destroy = true

    # Organizations reads these two only when it creates the account and never reports them back; without this every
    # plan would show a change or a replacement.
    ignore_changes = [role_name, iam_user_access_to_billing]
  }
}
