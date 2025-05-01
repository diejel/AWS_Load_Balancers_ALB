# **AWS Load Balancers Lab with Functional Backends (ALB/NLB)**

## **Lab Architecture**
![ALB-NLB-Architecture](https://www.crio.do/blog/content/images/2022/08/Load-Balancing.png)

```hcl
# main.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# VPC Setup
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "LoadBalancer-Lab-VPC"
  }
}

# Public Subnets (For LBs and NAT)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = element(["us-east-1a", "us-east-1b"], count.index)
  map_public_ip_on_launch = true
  tags = {
    Name = "Public-Subnet-${count.index + 1}"
  }
}

# Private Subnets (For EC2 Instances)
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 2)
  availability_zone = element(["us-east-1a", "us-east-1b"], count.index)
  tags = {
    Name = "Private-Subnet-${count.index + 1}"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# Route Table for Public Subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Security Group for ALB
resource "aws_security_group" "alb_sg" {
  name        = "alb-security-group"
  description = "Allow HTTP inbound"
  vpc_id      = aws_vpc.main.id

  ingress {
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
}

# Security Group for EC2 (Allow HTTP from ALB + SSH for debugging)
resource "aws_security_group" "ec2_sg" {
  name        = "ec2-security-group"
  description = "Allow HTTP from ALB and SSH"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Restrict to your IP in production!
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ALB
resource "aws_lb" "web_alb" {
  name               = "web-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = aws_subnet.public[*].id
}

# Target Group for ALB
resource "aws_lb_target_group" "web_tg" {
  name     = "web-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# ALB Listener
resource "aws_lb_listener" "web" {
  load_balancer_arn = aws_lb.web_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}

# NLB
resource "aws_lb" "api_nlb" {
  name               = "api-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = aws_subnet.public[*].id
}

# Target Group for NLB
resource "aws_lb_target_group" "api_tg" {
  name        = "api-target-group"
  port        = 8080 # Sample API port
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    interval = 30
  }
}

# NLB Listener
resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api_nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api_tg.arn
  }
}

# EC2 Launch Template (For both web and API instances)
resource "aws_launch_template" "backend" {
  name_prefix   = "backend-"
  image_id      = "ami-0c7217cdde317cfec" # Amazon Linux 2023 (Free Tier)
  instance_type = "t2.micro"
  key_name      = aws_key_pair.demo.key_name

  user_data = base64encode(<<-EOF
    #!/bin/bash
    # Install web server (Apache for ALB demo)
    yum install -y httpd
    systemctl start httpd
    systemctl enable httpd

    # Create unique homepage to identify instance
    echo "<h1>Hello from $(hostname -f) behind ALB!</h1>" > /var/www/html/index.html

    # Simple API listener (Netcat for NLB demo)
    echo "while true; do nc -l -p 8080 -c 'echo -e \"HTTP/1.1 200 OK\\n\\nAPI Response from $(hostname -f)\"'; done" > /run_api.sh
    chmod +x /run_api.sh
    nohup /run_api.sh &
  EOF
  )

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.ec2_sg.id]
  }
}

# Auto Scaling Group for Web Tier (ALB)
resource "aws_autoscaling_group" "web" {
  desired_capacity    = 2
  max_size           = 2
  min_size           = 2
  vpc_zone_identifier = aws_subnet.private[*].id
  target_group_arns   = [aws_lb_target_group.web_tg.arn]

  launch_template {
    id      = aws_launch_template.backend.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "Web-Server"
    propagate_at_launch = true
  }
}

# Auto Scaling Group for API Tier (NLB)
resource "aws_autoscaling_group" "api" {
  desired_capacity    = 2
  max_size           = 2
  min_size           = 2
  vpc_zone_identifier = aws_subnet.private[*].id
  target_group_arns   = [aws_lb_target_group.api_tg.arn]

  launch_template {
    id      = aws_launch_template.backend.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "API-Server"
    propagate_at_launch = true
  }
}

# SSH Key (For debugging - delete after lab)
resource "aws_key_pair" "demo" {
  key_name   = "demo-key"
  public_key = "ssh-rsa AAAAB3NzaC...== user@example.com" # Replace with your public key
}

# Outputs
output "alb_dns" {
  value = aws_lb.web_alb.dns_name
}

output "nlb_dns" {
  value = aws_lb.api_nlb.dns_name
}

output "test_commands" {
  value = <<EOF
Test ALB (Web Tier):
  curl http://${aws_lb.web_alb.dns_name}

Test NLB (API Tier):
  curl --connect-timeout 3 http://${aws_lb.api_nlb.dns_name}:80

SSH to instances (for debugging):
  ssh -i ~/.ssh/demo-key ec2-user@<private-ip> -o ProxyCommand="ssh -i ~/.ssh/demo-key -W %h:%p ec2-user@${aws_instance.bastion.public_ip}"
EOF
}
```
## Validation Steps

### Deploy the stack:

```hcl
terraform init && terraform apply -auto-approve
```

### Test the ALB (Web Tier):

```hcl
curl http://<ALB_DNS_NAME>
```

### Expected Response:

```html
<h1>Hello from ip-10-0-3-12.ec2.internal behind ALB!</h1>
```

(Refresh multiple times to see different instance hostnames)

### Test the NLB (API Tier):

```bash
curl --connect-timeout 3 http://<NLB_DNS_NAME>:80
```

### Expected Response:

`API Response from ip-10-0-4-67.ec2.internal`

## Key Observations

| Load Balancer | Test Method        | Expected Behavior                             |
| ------------- | ------------------ | --------------------------------------------- |
| ALB           | HTTP GET /         | Rotates responses between EC2 instances       |
| NLB           | Raw TCP on port 80 | Returns API response with instance ID         |
| GWLB          | Not deployed       | Would inspect traffic via security appliances |

## Cleanup

```bash
terraform destroy -auto-approve
```

## Production Notes

### 1- ALB Enhancements:

- Replace HTTP with HTTPS (ACM certificates)

- Enable access logs to S3

```hcl
resource "aws_lb" "prod_alb" {
  access_logs {
    bucket  = aws_s3_bucket.logs.bucket
    prefix  = "alb"
    enabled = true
  }
}
```

### 2- NLB Enhancements:

- Add Elastic IPs for static endpoints

```hcl
resource "aws_lb" "prod_nlb" {
  subnet_mapping {
    subnet_id     = aws_subnet.public[0].id
    allocation_id = aws_eip.nlb[0].id
  }
}
```

### 3- GWLB (Uncomment for Production):

```hcl
resource "aws_lb" "gwlb" {
  load_balancer_type = "gateway"
  subnet_mapping {
    subnet_id = aws_subnet.security[0].id
  }
}
```


This lab provides:
- **Real EC2 backends** with auto-scaling groups
- **Functional web servers** (Apache) for ALB demo
- **Raw TCP API** (Netcat) for NLB demo
- **Clear validation steps** with expected outputs
- **Production-ready enhancements** as commented code