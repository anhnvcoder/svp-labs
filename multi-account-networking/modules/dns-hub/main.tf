# Central DNS of the network account. Two ways to give a spoke VPC a private hosted zone of another account: the zone
# net goes into a Route 53 Profile that each spoke associates once; the zone nonprd uses the older pair of an
# authorization here and an association in the spoke's account. Design notes: multi-account-networking/README.md.
locals {
  zones = {
    net    = "net.svp.example"
    nonprd = "nonprd.svp.example"
  }

  records = merge([
    for z, hosts in var.records : { for h, ip in hosts : "${h}.${z}" => { zone = z, host = h, ip = ip } }
  ]...)
}

resource "aws_route53_zone" "this" {
  for_each = local.zones

  name    = each.value
  comment = "Private zone of the multi-account networking lab"

  # A private zone is created with one VPC of its own account; the spokes join it through other resources, which the
  # inline block would remove at the next apply.
  vpc {
    vpc_id = var.vpc_id
  }

  lifecycle {
    ignore_changes = [vpc]
  }
}

resource "aws_route53_record" "this" {
  for_each = local.records

  zone_id = aws_route53_zone.this[each.value.zone].zone_id
  name    = "${each.value.host}.${local.zones[each.value.zone]}"
  type    = "A"
  ttl     = 60
  records = [each.value.ip]
}

# The zone owner's half of an association across accounts; the VPC owner makes the association.
resource "aws_route53_vpc_association_authorization" "nonprd" {
  for_each = var.nonprd_vpc_ids

  zone_id = aws_route53_zone.this["nonprd"].zone_id
  vpc_id  = each.value
}

resource "aws_route53profiles_profile" "this" {
  name = var.name

  tags = {
    Name = var.name
  }
}

resource "aws_route53profiles_resource_association" "net" {
  name         = "${var.name}-net"
  profile_id   = aws_route53profiles_profile.this.id
  resource_arn = aws_route53_zone.this["net"].arn
}
