# The spoke's half of the central DNS: the Profile shared through RAM, and the zones whose owner authorized this VPC.
resource "aws_route53profiles_association" "this" {
  name        = var.name
  profile_id  = var.profile_id
  resource_id = var.vpc_id

  tags = {
    Name = var.name
  }
}

resource "aws_route53_zone_association" "this" {
  for_each = var.zone_ids

  zone_id = each.value
  vpc_id  = var.vpc_id
}
