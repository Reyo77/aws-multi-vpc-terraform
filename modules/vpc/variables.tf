variable "name" {
  description = "Short name used in resource Name tags (e.g. shared, dev, prod)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC (a /16)"
  type        = string
}

variable "az" {
  description = "Availability zone for both subnets"
  type        = string
}
