data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_instance" "control_plane" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.control_plane_instance_type
  key_name                = var.key_name
  subnet_id               = aws_subnet.phoenix_public.id
  vpc_security_group_ids  = [aws_security_group.phoenix_nodes.id]

  tags = {
    Name = "phoenix-control-plane"
    Role = "control-plane"
  }
}

resource "aws_instance" "worker" {
  count                   = var.worker_count
  ami                     = data.aws_ami.ubuntu.id
  instance_type           = var.worker_instance_type
  key_name                = var.key_name
  subnet_id               = aws_subnet.phoenix_public.id
  vpc_security_group_ids  = [aws_security_group.phoenix_nodes.id]

  tags = {
    Name = "phoenix-worker-${count.index + 1}"
    Role = "worker"
  }
}

output "control_plane_public_ip" {
  value = aws_instance.control_plane.public_ip
}

output "worker_public_ips" {
  value = aws_instance.worker[*].public_ip
}