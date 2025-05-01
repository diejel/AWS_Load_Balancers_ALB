# main.tf - Complete ALB Solution with Ubuntu EC2 Instances

# Provider configuration
provider "aws" {
  region = "us-east-1"
}

# Networking
resource "aws_vpc" "shopfast_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "ShopFast-VPC"
  }
}

resource "aws_subnet" "public_subnet_1" {
  vpc_id            = aws_vpc.shopfast_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
  tags = {
    Name = "ShopFast-Public-1a"
  }
}

resource "aws_subnet" "public_subnet_2" {
  vpc_id            = aws_vpc.shopfast_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"
  tags = {
    Name = "ShopFast-Public-1b"
  }
}

resource "aws_internet_gateway" "shopfast_igw" {
  vpc_id = aws_vpc.shopfast_vpc.id
  tags = {
    Name = "ShopFast-IGW"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.shopfast_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.shopfast_igw.id
  }
  tags = {
    Name = "ShopFast-Public-RT"
  }
}

resource "aws_route_table_association" "public_1_rt_assoc" {
  subnet_id      = aws_subnet.public_subnet_1.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_2_rt_assoc" {
  subnet_id      = aws_subnet.public_subnet_2.id
  route_table_id = aws_route_table.public_rt.id
}

# Security Groups
resource "aws_security_group" "alb_sg" {
  name        = "shopfast-alb-sg"
  description = "Allow HTTP inbound traffic"
  vpc_id      = aws_vpc.shopfast_vpc.id

  ingress {
    description = "HTTP from Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ShopFast-ALB-SG"
  }
}

resource "aws_security_group" "ec2_sg" {
  name        = "shopfast-ec2-sg"
  description = "Allow HTTP from ALB and SSH"
  vpc_id      = aws_vpc.shopfast_vpc.id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["179.160.5.171/32"] # Replace with your IP
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ShopFast-EC2-SG"
  }
}

# Load Balancer Components
resource "aws_lb" "shopfast_alb" {
  name               = "shopfast-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]

  enable_deletion_protection = false

  tags = {
    Name = "ShopFast-ALB"
  }
}

resource "aws_lb_target_group" "shopfast_tg" {
  name     = "shopfast-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.shopfast_vpc.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "shopfast_http" {
  load_balancer_arn = aws_lb.shopfast_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.shopfast_tg.arn
  }
}

# Ubuntu EC2 Instances (apt-based)
resource "aws_launch_template" "shopfast_ubuntu_lt" {
  name_prefix   = "shopfast-ubuntu-lt"
  image_id      = "ami-0fc5d935ebf8bc3bc" # Ubuntu 22.04 LTS in us-east-1
  instance_type = "t2.micro"
  key_name      = "ec2_tutorial" # Replace with your key pair name

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.ec2_sg.id]
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              # Ubuntu-specific configuration
              apt-get update -y
              apt-get install -y apache2
              systemctl start apache2
              systemctl enable apache2
              echo "<html><body><h1>ShopFast Ubuntu Server $(hostname -f)</h1>" > /var/www/html/index.html
              echo "<p>Availability Zone: $(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)</p></body></html>" >> /var/www/html/index.html
              EOF
              )
}

resource "aws_autoscaling_group" "shopfast_asg" {
  desired_capacity    = 2
  max_size            = 2
  min_size            = 2

  vpc_zone_identifier = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]

  launch_template {
    id      = aws_launch_template.shopfast_ubuntu_lt.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.shopfast_tg.arn]

  tag {
    key                 = "Name"
    value               = "ShopFast-Ubuntu-WebServer"
    propagate_at_launch = true
  }
}

