resource "aws_vpc" "phoenix" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "phoenix-vpc"
  }
}

resource "aws_subnet" "phoenix_public" {
  vpc_id                  = aws_vpc.phoenix.id
  cidr_block              = "10.10.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"

  tags = {
    Name = "phoenix-public-subnet"
  }
}

resource "aws_internet_gateway" "phoenix" {
  vpc_id = aws_vpc.phoenix.id

  tags = {
    Name = "phoenix-igw"
  }
}

resource "aws_route_table" "phoenix_public" {
  vpc_id = aws_vpc.phoenix.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.phoenix.id
  }

  tags = {
    Name = "phoenix-public-rt"
  }
}

resource "aws_route_table_association" "phoenix_public" {
  subnet_id      = aws_subnet.phoenix_public.id
  route_table_id = aws_route_table.phoenix_public.id
}