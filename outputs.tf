
# Outputs
output "alb_dns_name" {
  value       = aws_lb.shopfast_alb.dns_name
  description = "The DNS name of the Application Load Balancer"
}



#output "ec2_public_ips" {
#  description = "Public IPs of the EC2 instances"
#  value       = aws_autoscaling_group.shopfast_asg.instances[*].public_ip
#}

data "aws_instances" "asg_instances" {
  depends_on = [aws_autoscaling_group.shopfast_asg]
  filter {
    name   = "tag:Name"
    values = ["ShopFast-Ubuntu-WebServer"] # Replace with the tag name of your instances
  }
}


output "ec2_public_ips" {
  description = "Public IPs of the EC2 instances"
  value       = data.aws_instances.asg_instances.public_ips
}

output "ubuntu_ssh_instruction" {
  value = <<EOT
To SSH into Ubuntu instances:
ssh -i your-key.pem ubuntu@[${join(", ", data.aws_instances.asg_instances.public_ips)}]
Default username: ubuntu
EOT
}
