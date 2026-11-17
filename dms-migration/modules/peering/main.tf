# The private link between the on-premises stand-in and the AWS side: a VPC peering connection, the cheapest path in
# one account and one Region, standing in for a Site-to-Site VPN or Direct Connect. Each side routes only the other
# side's range through it. Design notes: dms-migration/README.md.

resource "aws_vpc_peering_connection" "this" {
  vpc_id      = var.requester.vpc_id
  peer_vpc_id = var.accepter.vpc_id
  auto_accept = true

  tags = {
    Name = var.name
  }
}

resource "aws_route" "requester" {
  route_table_id            = var.requester.route_table_id
  destination_cidr_block    = var.accepter.cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

resource "aws_route" "accepter" {
  route_table_id            = var.accepter.route_table_id
  destination_cidr_block    = var.requester.cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}
