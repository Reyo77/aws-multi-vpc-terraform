output "my_ip_cidr" {
  description = "Public IPv4 /32 allowed to SSH to the bastion"
  value       = local.my_ip_cidr
}

output "bastion_public_ip" {
  description = "Public IP of the bastion (the only instance with one)"
  value       = aws_instance.this["bastion"].public_ip
}

output "bastion_private_ip" {
  value = aws_instance.this["bastion"].private_ip
}

output "dev_app_private_ip" {
  value = aws_instance.this["dev-app"].private_ip
}

output "prod_app_private_ip" {
  value = aws_instance.this["prod-app"].private_ip
}

output "instance_ids" {
  value = { for k, i in aws_instance.this : k => i.id }
}
