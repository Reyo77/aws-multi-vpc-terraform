# Hub-and-spoke: shared-services peers with dev and with prod. Dev and prod are NOT peered.
resource "aws_vpc_peering_connection" "shared_dev" {
  vpc_id      = module.shared.vpc_id
  peer_vpc_id = module.dev.vpc_id
  auto_accept = true

  tags = { Name = "p1-shared-dev-pcx" }
}

resource "aws_vpc_peering_connection" "shared_prod" {
  vpc_id      = module.shared.vpc_id
  peer_vpc_id = module.prod.vpc_id
  auto_accept = true

  tags = { Name = "p1-shared-prod-pcx" }
}

# shared -> dev / prod
locals {
  shared_route_tables = {
    public  = module.shared.public_route_table_id
    private = module.shared.private_route_table_id
  }
  dev_route_tables = {
    public  = module.dev.public_route_table_id
    private = module.dev.private_route_table_id
  }
  prod_route_tables = {
    public  = module.prod.public_route_table_id
    private = module.prod.private_route_table_id
  }
}

resource "aws_route" "shared_to_dev" {
  for_each = local.shared_route_tables

  route_table_id            = each.value
  destination_cidr_block    = module.dev.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.shared_dev.id
}

resource "aws_route" "shared_to_prod" {
  for_each = local.shared_route_tables

  route_table_id            = each.value
  destination_cidr_block    = module.prod.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.shared_prod.id
}

# dev / prod -> shared
resource "aws_route" "dev_to_shared" {
  for_each = local.dev_route_tables

  route_table_id            = each.value
  destination_cidr_block    = module.shared.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.shared_dev.id
}

resource "aws_route" "prod_to_shared" {
  for_each = local.prod_route_tables

  route_table_id            = each.value
  destination_cidr_block    = module.shared.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.shared_prod.id
}
