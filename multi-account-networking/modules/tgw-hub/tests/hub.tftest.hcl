# Routing decisions of the hub with the CIDRs of the lab, then one plan per validation rule. The AWS provider is a
# mock: nothing reaches an account. Route table ids exist only after apply, so the assertions read the table of each
# route and attachment from the module's locals and compare attachment ids, which the test gives.

mock_provider "aws" {}

variables {
  name = "svp-lab-net"
  attachments = {
    egress = { id = "tgw-attach-0aaaaaaaaaaaaaaa1", cidr = "10.64.0.0/20" }
    shared = { id = "tgw-attach-0bbbbbbbbbbbbbbb2", cidr = "10.64.16.0/20" }
    stg    = { id = "tgw-attach-0ccccccccccccccc3", cidr = "10.64.32.0/20" }
    prd    = { id = "tgw-attach-0ddddddddddddddd4", cidr = "10.64.48.0/20" }
  }
}

run "routing" {
  command = plan

  assert {
    condition = (aws_ec2_transit_gateway.this.default_route_table_association == "disable" &&
    aws_ec2_transit_gateway.this.default_route_table_propagation == "disable")
    error_message = "The transit gateway must have no default route table: every attachment is associated by hand."
  }

  assert {
    condition     = aws_ec2_transit_gateway.this.auto_accept_shared_attachments == "enable"
    error_message = "Attachments of the spoke accounts must be accepted without a manual step."
  }

  assert {
    condition     = toset(keys(aws_ec2_transit_gateway_route_table.this)) == toset(["prd", "nonprd", "egress"])
    error_message = "The hub must have exactly three route tables: prd, nonprd and egress."
  }

  assert {
    condition     = local.route_table_of == { egress = "egress", shared = "nonprd", stg = "nonprd", prd = "prd" }
    error_message = "shared and stg must join the non-prd table, prd the prd table and egress the egress table."
  }

  assert {
    condition     = [for k, t in local.route_table_of : k if t == "egress"] == ["egress"]
    error_message = "The egress table must hold the attachment of the egress VPC alone."
  }

  assert {
    condition = (length(aws_ec2_transit_gateway_route_table_association.this) == 4 &&
      alltrue([for k, a in aws_ec2_transit_gateway_route_table_association.this :
    a.transit_gateway_attachment_id == var.attachments[k].id]))
    error_message = "Each of the four attachments must be associated once, with its own id."
  }

  assert {
    condition = (aws_ec2_transit_gateway_route.this["prd|0.0.0.0/0"].transit_gateway_attachment_id == "tgw-attach-0aaaaaaaaaaaaaaa1" &&
    aws_ec2_transit_gateway_route.this["nonprd|0.0.0.0/0"].transit_gateway_attachment_id == "tgw-attach-0aaaaaaaaaaaaaaa1")
    error_message = "Both env tables must send 0.0.0.0/0 to the egress attachment."
  }

  assert {
    condition = (aws_ec2_transit_gateway_route.this["prd|10.64.16.0/20"].blackhole &&
      aws_ec2_transit_gateway_route.this["prd|10.64.32.0/20"].blackhole &&
    aws_ec2_transit_gateway_route.this["nonprd|10.64.48.0/20"].blackhole)
    error_message = "The prd table must blackhole stg and shared, the non-prd table must blackhole prd."
  }

  assert {
    condition = (alltrue([for k, r in local.routes : r.attachment == null || r.attachment == "egress" || r.attachment == "prd" if r.table == "prd"]) &&
    alltrue([for k, r in local.routes : r.attachment != "prd" if r.table == "nonprd"]))
    error_message = "No route may join prd and stg (or the shared VPC) in either direction."
  }

  assert {
    condition = (aws_ec2_transit_gateway_route.this["nonprd|10.64.16.0/20"].transit_gateway_attachment_id == "tgw-attach-0bbbbbbbbbbbbbbb2" &&
    aws_ec2_transit_gateway_route.this["nonprd|10.64.32.0/20"].transit_gateway_attachment_id == "tgw-attach-0ccccccccccccccc3")
    error_message = "The non-prd table must route to the shared VPC and back to stg."
  }

  assert {
    condition = (aws_ec2_transit_gateway_route.this["egress|10.64.16.0/20"].transit_gateway_attachment_id == "tgw-attach-0bbbbbbbbbbbbbbb2" &&
      aws_ec2_transit_gateway_route.this["egress|10.64.32.0/20"].transit_gateway_attachment_id == "tgw-attach-0ccccccccccccccc3" &&
    aws_ec2_transit_gateway_route.this["egress|10.64.48.0/20"].transit_gateway_attachment_id == "tgw-attach-0ddddddddddddddd4")
    error_message = "The egress table must route the CIDR of shared, stg and prd back to their attachments."
  }

  assert {
    condition     = !contains(keys(local.routes), "egress|0.0.0.0/0") && !contains(keys(local.routes), "egress|10.64.0.0/20")
    error_message = "The egress table must hold only the return routes to the spokes."
  }

  assert {
    condition     = length(aws_ec2_transit_gateway_route.this) == 11
    error_message = "Expected 11 routes: 2 defaults, 3 in each env table, 3 return routes."
  }
}

run "attachments_missing_shared" {
  command = plan

  variables {
    attachments = {
      egress = { id = "tgw-attach-0aaaaaaaaaaaaaaa1", cidr = "10.64.0.0/20" }
      stg    = { id = "tgw-attach-0ccccccccccccccc3", cidr = "10.64.32.0/20" }
      prd    = { id = "tgw-attach-0ddddddddddddddd4", cidr = "10.64.48.0/20" }
    }
  }

  expect_failures = [var.attachments]
}

run "attachments_default_cidr" {
  command = plan

  variables {
    attachments = {
      egress = { id = "tgw-attach-0aaaaaaaaaaaaaaa1", cidr = "0.0.0.0/0" }
      shared = { id = "tgw-attach-0bbbbbbbbbbbbbbb2", cidr = "10.64.16.0/20" }
      stg    = { id = "tgw-attach-0ccccccccccccccc3", cidr = "10.64.32.0/20" }
      prd    = { id = "tgw-attach-0ddddddddddddddd4", cidr = "10.64.48.0/20" }
    }
  }

  expect_failures = [var.attachments]
}

run "attachments_same_cidr" {
  command = plan

  variables {
    attachments = {
      egress = { id = "tgw-attach-0aaaaaaaaaaaaaaa1", cidr = "10.64.0.0/20" }
      shared = { id = "tgw-attach-0bbbbbbbbbbbbbbb2", cidr = "10.64.32.0/20" }
      stg    = { id = "tgw-attach-0ccccccccccccccc3", cidr = "10.64.32.0/20" }
      prd    = { id = "tgw-attach-0ddddddddddddddd4", cidr = "10.64.48.0/20" }
    }
  }

  expect_failures = [var.attachments]
}

run "name_uppercase" {
  command = plan

  variables {
    name = "Svp-lab-net"
  }

  expect_failures = [var.name]
}
