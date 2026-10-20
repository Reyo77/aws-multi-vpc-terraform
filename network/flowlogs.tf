# One flow log per VPC, all writing to the bucket from the separate logging stack.
# ALL = both ACCEPT and REJECT records; 60s aggregation so evidence shows up quickly.
locals {
  flow_log_vpcs = {
    shared = module.shared.vpc_id
    dev    = module.dev.vpc_id
    prod   = module.prod.vpc_id
  }
}

resource "aws_flow_log" "this" {
  for_each = local.flow_log_vpcs

  vpc_id                   = each.value
  traffic_type             = "ALL"
  log_destination_type     = "s3"
  log_destination          = var.flow_logs_bucket_arn
  max_aggregation_interval = 60

  tags = { Name = "p1-${each.key}-flowlog" }
}
