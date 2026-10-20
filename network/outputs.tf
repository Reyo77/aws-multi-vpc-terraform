output "my_ip_cidr" {
  description = "Public IPv4 /32 allowed to SSH to the bastion"
  value       = local.my_ip_cidr
}
