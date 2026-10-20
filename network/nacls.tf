# Custom NACLs for the dev and prod private subnets. NACLs are stateless, so return traffic
# (ephemeral ports) needs its own rules in both directions. Rules are separate
# aws_network_acl_rule resources (no inline rules) so Terraform manages them one by one.
locals {
  private_subnets = {
    dev  = module.dev
    prod = module.prod
  }

  nacl_rules = {
    in_ssh       = { egress = false, number = 100, protocol = "6", from = 22, to = 22, action = "allow" }
    in_icmp      = { egress = false, number = 110, protocol = "1", from = 0, to = 0, action = "allow" }
    in_ephemeral = { egress = false, number = 120, protocol = "6", from = 1024, to = 65535, action = "allow" }
    in_deny      = { egress = false, number = 900, protocol = "-1", from = 0, to = 0, action = "deny", cidr = "0.0.0.0/0" }
    out_icmp     = { egress = true, number = 100, protocol = "1", from = 0, to = 0, action = "allow" }
    out_ephem    = { egress = true, number = 110, protocol = "6", from = 1024, to = 65535, action = "allow" }
    out_deny     = { egress = true, number = 900, protocol = "-1", from = 0, to = 0, action = "deny", cidr = "0.0.0.0/0" }
  }

  nacl_rule_instances = {
    for pair in setproduct(keys(local.private_subnets), keys(local.nacl_rules)) :
    "${pair[0]}-${pair[1]}" => {
      env  = pair[0]
      rule = local.nacl_rules[pair[1]]
    }
  }
}

resource "aws_network_acl" "private" {
  for_each = local.private_subnets

  vpc_id     = each.value.vpc_id
  subnet_ids = [each.value.private_subnet_id]

  tags = { Name = "p1-${each.key}-private-nacl" }
}

resource "aws_network_acl_rule" "private" {
  for_each = local.nacl_rule_instances

  network_acl_id = aws_network_acl.private[each.value.env].id
  egress         = each.value.rule.egress
  rule_number    = each.value.rule.number
  rule_action    = each.value.rule.action
  protocol       = each.value.rule.protocol
  cidr_block     = lookup(each.value.rule, "cidr", module.shared.vpc_cidr)

  # TCP uses the port range; ICMP uses type/code (-1 = all); "deny all" uses neither.
  from_port = each.value.rule.protocol == "6" ? each.value.rule.from : null
  to_port   = each.value.rule.protocol == "6" ? each.value.rule.to : null
  icmp_type = each.value.rule.protocol == "1" ? -1 : null
  icmp_code = each.value.rule.protocol == "1" ? -1 : null
}
