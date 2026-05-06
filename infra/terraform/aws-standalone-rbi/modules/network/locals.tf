locals {
  public_subnets = {
    for index, cidr in var.public_subnet_cidrs : var.availability_zones[index] => {
      az   = var.availability_zones[index]
      cidr = cidr
    }
  }

  private_subnets = {
    for index, cidr in var.private_subnet_cidrs : var.availability_zones[index] => {
      az   = var.availability_zones[index]
      cidr = cidr
    }
  }

  data_subnets = {
    for index, cidr in var.data_subnet_cidrs : var.availability_zones[index] => {
      az   = var.availability_zones[index]
      cidr = cidr
    }
  }

  nat_gateway_azs = var.enable_nat_gateway ? (
    var.single_nat_gateway ? [var.availability_zones[0]] : var.availability_zones
  ) : []

  endpoint_route_table_ids = concat(
    values(aws_route_table.private)[*].id,
    values(aws_route_table.data)[*].id
  )

  tags = merge(
    var.tags,
    {
      Module = "network"
    }
  )
}
