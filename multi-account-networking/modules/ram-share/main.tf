resource "aws_ram_resource_share" "this" {
  name = var.name

  # Only accounts of the organization: with sharing in the organization on, they get the resource without an
  # invitation, and an account outside it cannot be added by mistake.
  allow_external_principals = false

  tags = {
    Name = var.name
  }
}

resource "aws_ram_resource_association" "this" {
  for_each = var.resource_arns

  resource_arn       = each.value
  resource_share_arn = aws_ram_resource_share.this.arn
}

resource "aws_ram_principal_association" "this" {
  for_each = toset(var.principals)

  principal          = each.key
  resource_share_arn = aws_ram_resource_share.this.arn
}
