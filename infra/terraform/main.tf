terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "phoenix-tfstate-voddy001"
    key            = "phoenix/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "phoenix-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}