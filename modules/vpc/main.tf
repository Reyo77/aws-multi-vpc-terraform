locals {
  public_subnet_cidr  = cidrsubnet(var.vpc_cidr, 8, 0)
  private_subnet_cidr = cidrsubnet(var.vpc_cidr, 8, 1)
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "p1-${var.name}-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_subnet_cidr
  availability_zone = var.az

  tags = { Name = "p1-${var.name}-public" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidr
  availability_zone = var.az

  tags = { Name = "p1-${var.name}-private" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "p1-${var.name}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "p1-${var.name}-public-rt" }
}

# A separate aws_route (not an inline route block) so it does not clash with the
# peering aws_route resources added in the network stack.
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

# Only the implicit local route: no way out of the VPC.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "p1-${var.name}-private-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}
