variable "region" {
  description = "AWS region for the whole project"
  type        = string
}

variable "az" {
  description = "Availability zone for every subnet"
  type        = string
}

variable "public_key_path" {
  description = "Path to the SSH public key used for the key pair"
  type        = string
}

variable "my_ip_override" {
  description = "Optional IPv4 CIDR (e.g. 203.0.113.7/32) used instead of the automatic lookup"
  type        = string
  default     = ""

  validation {
    condition     = var.my_ip_override == "" || can(regex("^\\d{1,3}(\\.\\d{1,3}){3}/32$", var.my_ip_override))
    error_message = "my_ip_override must be empty or an IPv4 /32 such as 203.0.113.7/32."
  }
}
