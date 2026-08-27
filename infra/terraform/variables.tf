variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "key_name" {
  description = "Name of existing EC2 key pair for SSH access"
  type        = string
  default     = "phoenix-cluster"
}

variable "control_plane_instance_type" {
  description = "Instance type for the k3s control-plane node"
  type        = string
  default     = "t3.medium"
}

variable "worker_instance_type" {
  description = "Instance type for the k3s worker nodes"
  type        = string
  default     = "t3.small"
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "my_ip" {
  description = "Your public IP, for restricting SSH access (CIDR format, e.g. 1.2.3.4/32)"
  type        = string
}