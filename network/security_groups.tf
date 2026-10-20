locals {
  shared_cidr = module.shared.vpc_cidr
  dev_cidr    = module.dev.vpc_cidr
  prod_cidr   = module.prod.vpc_cidr
}

# ---- bastion (shared-services) ----
resource "aws_security_group" "bastion" {
  name        = "p1-bastion-sg"
  description = "Bastion: SSH in from my IP only; SSH/ICMP out to dev and prod"
  vpc_id      = module.shared.vpc_id

  tags = { Name = "p1-bastion-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "bastion_ssh" {
  security_group_id = aws_security_group.bastion.id
  description       = "SSH from my public IPv4"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = local.my_ip_cidr
}

resource "aws_vpc_security_group_egress_rule" "bastion_ssh" {
  for_each = { dev = local.dev_cidr, prod = local.prod_cidr }

  security_group_id = aws_security_group.bastion.id
  description       = "SSH to ${each.key}"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "bastion_icmp" {
  for_each = { dev = local.dev_cidr, prod = local.prod_cidr }

  security_group_id = aws_security_group.bastion.id
  description       = "ICMP to ${each.key}"
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
  cidr_ipv4         = each.value
}

# Only here to generate a blocked-traffic test: prod has no inbound 3306, so it is REJECTed.
resource "aws_vpc_security_group_egress_rule" "bastion_mysql_prod" {
  security_group_id = aws_security_group.bastion.id
  description       = "TCP 3306 to prod (blocked-traffic test)"
  ip_protocol       = "tcp"
  from_port         = 3306
  to_port           = 3306
  cidr_ipv4         = local.prod_cidr
}

# ---- dev workload ----
resource "aws_security_group" "dev_workload" {
  name        = "p1-dev-workload-sg"
  description = "Dev workloads: SSH/ICMP in from shared-services only"
  vpc_id      = module.dev.vpc_id

  tags = { Name = "p1-dev-workload-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "dev_ssh" {
  security_group_id = aws_security_group.dev_workload.id
  description       = "SSH from shared-services"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = local.shared_cidr
}

resource "aws_vpc_security_group_ingress_rule" "dev_icmp" {
  security_group_id = aws_security_group.dev_workload.id
  description       = "ICMP from shared-services"
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
  cidr_ipv4         = local.shared_cidr
}

resource "aws_vpc_security_group_egress_rule" "dev_all" {
  security_group_id = aws_security_group.dev_workload.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---- prod workload ----
resource "aws_security_group" "prod_workload" {
  name        = "p1-prod-workload-sg"
  description = "Prod workloads: SSH/ICMP in from shared-services only; nothing on 3306"
  vpc_id      = module.prod.vpc_id

  tags = { Name = "p1-prod-workload-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "prod_ssh" {
  security_group_id = aws_security_group.prod_workload.id
  description       = "SSH from shared-services"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = local.shared_cidr
}

resource "aws_vpc_security_group_ingress_rule" "prod_icmp" {
  security_group_id = aws_security_group.prod_workload.id
  description       = "ICMP from shared-services"
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
  cidr_ipv4         = local.shared_cidr
}

resource "aws_vpc_security_group_egress_rule" "prod_all" {
  security_group_id = aws_security_group.prod_workload.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
