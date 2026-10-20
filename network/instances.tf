# Latest Amazon Linux 2023 AMI, resolved at plan time from the public SSM parameter.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_key_pair" "project1" {
  key_name   = "p1-key"
  public_key = file(pathexpand(var.public_key_path))

  tags = { Name = "p1-key" }
}

locals {
  instances = {
    bastion = {
      subnet_id = module.shared.public_subnet_id
      sg_id     = aws_security_group.bastion.id
      public_ip = true
    }
    dev-app = {
      subnet_id = module.dev.private_subnet_id
      sg_id     = aws_security_group.dev_workload.id
      public_ip = false
    }
    prod-app = {
      subnet_id = module.prod.private_subnet_id
      sg_id     = aws_security_group.prod_workload.id
      public_ip = false
    }
  }
}

resource "aws_instance" "this" {
  for_each = local.instances

  ami                         = data.aws_ssm_parameter.al2023.insecure_value
  instance_type               = "t3.micro"
  key_name                    = aws_key_pair.project1.key_name
  subnet_id                   = each.value.subnet_id
  vpc_security_group_ids      = [each.value.sg_id]
  associate_public_ip_address = each.value.public_ip

  # IMDSv2 only (blocks the older, SSRF-prone metadata API).
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 8
  }

  tags = { Name = "p1-${each.key}" }
}
