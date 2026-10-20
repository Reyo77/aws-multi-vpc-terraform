# Looked up fresh on every plan/apply because mobile IPv4 addresses change often.
data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"

  lifecycle {
    postcondition {
      condition     = can(regex("^\\d{1,3}(\\.\\d{1,3}){3}$", chomp(self.response_body)))
      error_message = "checkip.amazonaws.com did not return an IPv4 address."
    }
  }
}

locals {
  my_ip_cidr = var.my_ip_override != "" ? var.my_ip_override : "${chomp(data.http.my_ip.response_body)}/32"
}

module "shared" {
  source = "../modules/vpc"

  name     = "shared"
  vpc_cidr = "10.0.0.0/16"
  az       = var.az
}
