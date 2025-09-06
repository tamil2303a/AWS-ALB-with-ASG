# main.tf - ALB + ASG example (single file)
terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
  required_version = ">= 1.2.0"
}

provider "aws" {
  region = var.aws_region
}

# --------------------
# Variables
# --------------------
variable "aws_region" { type = string; default = "us-east-1" }
variable "key_name" { type = string; default = "" } # set your key pair name if SSH required
variable "instance_type" { type = string; default = "t3.micro" }
variable "min_size" { type = number; default = 1 }
variable "max_size" { type = number; default = 2 }
variable "desired_capacity" { type = number; default = 1 }
variable "allowed_ssh_cidr" { type = string; default = "0.0.0.0/0" } # restrict in prod

# --------------------
# Data sources (default VPC and subnets)
# --------------------
data "aws_vpc" "default" { default = true }

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

# find an AMI (Ubuntu Jammy)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# --------------------
# Security groups
# --------------------
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow HTTP to ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
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

resource "aws_security_group" "instance_sg" {
  name        = "instance-sg"
  description = "Allow HTTP from ALB and SSH from admin"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description      = "HTTP from ALB"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    security_groups  = [aws_security_group.alb_sg.id]
  }

  ingress {
    description = "SSH from admin"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --------------------
# ALB + Target Group + Listener
# --------------------
resource "aws_lb" "alb" {
  name               = "demo-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = slice(data.aws_subnet_ids.default.ids, 0, 2) # pick first 2 subnets
  enable_deletion_protection = false
}

resource "aws_lb_target_group" "tg" {
  name     = "demo-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

# --------------------
# IAM role & instance profile (optional - helpful for SSM)
# --------------------
resource "aws_iam_role" "ec2_role" {
  name = "demo-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "demo-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# --------------------
# Launch template
# --------------------
locals {
  user_data = <<-USERDATA
              #!/bin/bash
              apt-get update
              DEBIAN_FRONTEND=noninteractive apt-get install -y nginx curl
              INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
              echo "<html><body><h1>Hello from ${INSTANCE_ID}</h1></body></html>" > /var/www/html/index.html
              systemctl enable nginx
              systemctl restart nginx
              USERDATA
}

resource "aws_launch_template" "lt" {
  name_prefix   = "demo-lt-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  vpc_security_group_ids = [aws_security_group.instance_sg.id]

  user_data = base64encode(local.user_data)
}

# --------------------
# Auto Scaling Group
# --------------------
resource "aws_autoscaling_group" "asg" {
  name                      = "demo-asg"
  max_size                  = var.max_size
  min_size                  = var.min_size
  desired_capacity          = var.desired_capacity
  vpc_zone_identifier       = data.aws_subnet_ids.default.ids
  launch_template {
    id      = aws_launch_template.lt.id
    version = "$Latest"
  }
  target_group_arns         = [aws_lb_target_group.tg.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 120
  tags = [
    {
      key                 = "Name"
      value               = "demo-asg-instance"
      propagate_at_launch = true
    }
  ]
  lifecycle {
    create_before_destroy = true
  }
}

# Target tracking policy (scale on average CPU)
resource "aws_autoscaling_policy" "cpu_target" {
  name                   = "asg-target-cpu"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50.0
  }
}

# --------------------
# Outputs
# --------------------
output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.alb.dns_name
}

output "asg_name" {
  description = "Auto Scaling Group name"
  value       = aws_autoscaling_group.asg.name
}
