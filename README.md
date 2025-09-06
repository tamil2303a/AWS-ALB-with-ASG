Nice — let’s build a complete guide for **“AWS Application Load Balancer (ALB) with Auto Scaling Group (ASG)”** in two parts:

1. **Manual (console & CLI) step-by-step** — good to understand the components and for one-off deployments.
2. **Automation with Terraform** — production/ repeatable approach (single Terraform script you can run).

I’ll also include a simple **user-data** script so EC2 instances run a basic web server and show their instance ID (so you can verify LB + ASG behavior), verification steps, and cleanup instructions. I’ll warn about cost at the end.

---

# Manual setup — high level & step-by-step

## Architecture summary (what we’ll create)

* VPC (use your existing VPC or the default VPC)
* Security groups:

  * ALB SG: allow HTTP (80) from anywhere
  * Instance SG: allow HTTP from ALB SG, optionally SSH from your IP
* Application Load Balancer (public) across at least 2 public subnets
* Target Group (HTTP/port 80) with health check `/`
* Launch Template (or Launch Configuration) that boots EC2 instances and runs a small web server via user-data
* Auto Scaling Group (ASG) that uses the Launch Template, attaches to the Target Group, scales between min/max
* Auto Scaling Policy (target tracking on CPU or step scaling with CloudWatch alarms)

---

## Load Testing for Auto Scaling

To demonstrate Auto Scaling in action, we generate artificial CPU load on the EC2 instances.  
This triggers the Target Tracking Scaling Policy (based on average CPU utilization) and causes the Auto Scaling Group to scale up.

### Steps
1. SSH into one of the running EC2 instances in the Auto Scaling Group:
   ```bash
   ssh -i <your-key>.pem ubuntu@<public-ip-of-instance>
   ```

## Manual console steps (AWS Management Console)

> Assumes you have AWS console access, a VPC with public subnets, and permission to create EC2, ALB, ASG, IAM resources.

1. **Choose Region & VPC**

   * Console → Region (pick one).
   * Console → VPC Dashboard → Note the VPC ID and at least two **public** subnets (ALB requires >=2 subnets in different AZs).

2. **Create security groups**

   * EC2 → Security Groups → Create `alb-sg`:

     * Inbound: HTTP (80) Source: `0.0.0.0/0`
     * Outbound: allow all (default)
   * Create `instance-sg`:

     * Inbound: HTTP (80) Source: `sg-id-of-alb-sg` (restrict to ALB SG)
     * Inbound (optional): SSH (22) Source: *your IP* (for troubleshooting)
     * Outbound: allow all

3. **Create Target Group**

   * EC2 → Target Groups → Create target group

     * Target type: `instance`
     * Protocol: `HTTP` Port `80`
     * VPC: your VPC
     * Health checks: HTTP path `/` (default), 30s interval is fine
     * Give a name like `tg-demo`

4. **Create Application Load Balancer**

   * EC2 → Load Balancers → Create Load Balancer → Application Load Balancer

     * Scheme: internet-facing
     * IP address type: ipv4
     * Select two or more public subnets (in different AZs)
     * Security group: assign `alb-sg`
     * Default listener: HTTP 80 — set default action to forward to your Target Group `tg-demo`
     * Create and note the **DNS name** (e.g., `my-alb-1234.us-east-1.elb.amazonaws.com`)

5. **Create Launch Template (or Launch Configuration)**

   * EC2 → Launch Templates → Create Launch Template

     * Name: `lt-demo`
     * AMI: choose Ubuntu/Amazon Linux (latest)
     * Instance type: e.g., `t3.micro` (within Free Tier if eligible)
     * Key pair: choose if you want SSH access
     * Network settings: leave default (will be set by ASG subnets)
     * Security groups: assign `instance-sg`
     * User data: paste a script that installs nginx and writes instance id to `/var/www/html/index.html` (see *User-data* section below)
   * Save

6. **Create Auto Scaling Group**

   * EC2 → Auto Scaling Groups → Create Auto Scaling group

     * Choose Launch template → select `lt-demo`
     * ASG name: `asg-demo`
     * Network: pick your VPC and at least two subnets (same as ALB subnets)
     * Attach to a load balancer: check “Attach to a new or existing load balancer”, choose target group `tg-demo`
     * Set group size: min = 1, desired = 1, max = 3 (example)
     * Configure scaling policies: choose “Target tracking scaling policy”:

       * Metric type: `ASGAverageCPUUtilization` or `ALBRequestCountPerTarget`
       * Target value: e.g., `50` for CPU
     * Create ASG

7. **Test**

   * Wait for instances to enter `InService` in Target Group (Health checks pass)

     * EC2 → Target Groups → Select `tg-demo` → Targets → Wait for healthy status
   * Visit the ALB DNS name in browser (`http://<alb-dns>`) → you should see the HTML page (shows instance id)
   * If you scale up/down (set ASG desired capacity or trigger load), you should see more instances registered by Target Group.

8. **Optional: Create CloudWatch alarms / advanced scaling**

   * CloudWatch → Alarms → Create alarm on `ASG CPU` metric or `TargetGroupRequestCount` → link to an Autoscaling policy (step scaling) for more control

9. **Cleanup (manual)**

   * Delete the ASG (delete or set desired=0 then delete)
   * Delete Launch Template
   * Delete ALB, Target Group, Security Groups
   * Terminate any EC2 instances and keypairs if created

---

## Useful CLI commands (for manual automation/commands)

> Replace variables accordingly (`--subnets`, `--vpc-id`, `--security-groups`, etc.).

* Create target group:

```bash
aws elbv2 create-target-group \
  --name tg-demo \
  --protocol HTTP --port 80 \
  --vpc-id <vpc-id> \
  --health-check-protocol HTTP \
  --health-check-path /
```

* Create ALB:

```bash
aws elbv2 create-load-balancer \
  --name alb-demo \
  --subnets subnet-aaa subnet-bbb \
  --security-groups sg-ALB
```

* Create listener:

```bash
aws elbv2 create-listener \
  --load-balancer-arn <alb-arn> \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn=<tg-arn>
```

* Create launch template (with user-data file `user-data.sh` base64 encoded):

```bash
aws ec2 create-launch-template --launch-template-name lt-demo \
  --launch-template-data '{
    "ImageId":"ami-xxxx",
    "InstanceType":"t3.micro",
    "SecurityGroupIds":["sg-instance"],
    "UserData":"<base64-encoded-user-data>"
  }'
```

* Create AutoScaling group:

```bash
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name asg-demo \
  --launch-template LaunchTemplateId=<id>,Version=1 \
  --min-size 1 --max-size 3 --desired-capacity 1 \
  --vpc-zone-identifier "subnet-aaa,subnet-bbb" \
  --target-group-arns <tg-arn>
```

* Create target tracking scaling policy (example via CLI is long — console is easier).

---

## User-data example (paste into Launch Template or use in Terraform)

This simple script installs nginx and writes the instance ID into the default page so when you browse the ALB you know which instance answered:

```bash
#!/bin/bash
set -e
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx curl
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
echo "<html><body><h1>Hello from $INSTANCE_ID</h1></body></html>" > /var/www/html/index.html
systemctl enable nginx
systemctl restart nginx
```

---

# Automation with Terraform — single-file example

Below is a **complete single `main.tf` Terraform script** (self-contained) you can tweak and run. It provisions an ALB + Target Group + Listener + Launch Template + Auto Scaling Group + security groups + IAM instance profile. It uses the default VPC and its public subnets (suitable for quick tests). **Adjust variables** before running.

> **Important:** Review variables (`key_name`, `allowed_ssh_cidr`, `region`) and replace defaults. Running this will create AWS resources that may incur cost.

```hcl
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
```

### How to run the Terraform script

1. Save the above as `main.tf` in a new folder.
2. Set variables (optional) create `terraform.tfvars`:

```hcl
aws_region      = "us-east-1"
key_name        = "my-keypair"          # optional if you want SSH
allowed_ssh_cidr = "203.0.113.4/32"     # your IP address
instance_type   = "t3.micro"
min_size        = 1
max_size        = 2
desired_capacity = 1
```

3. Initialize, plan, apply:

```bash
terraform init
terraform plan -out plan.out
terraform apply "plan.out"
```

4. After `apply` finishes, Terraform outputs `alb_dns_name`. Open `http://<alb_dns_name>` — you should see a page showing the instance id. If health checks are still initializing, wait a minute.

5. To scale manually:

```bash
aws autoscaling set-desired-capacity --auto-scaling-group-name <asg-name> --desired-capacity 2 --region <your-region>
```

Verify target group registrations in console or `aws elbv2 describe-target-health`.

6. To destroy:

```bash
terraform destroy
```

---

# Verification checklist & troubleshooting

* **ALB shows InService targets**: EC2 → Target Groups → Targets → Healthy
* **ALB DNS works in browser**: `http://<alb_dns>`
* **If ALB shows 503**: target group has no healthy targets (check instance health & security group)
* **If instance not reachable**: check instance security group, NACLs, and that nginx is running (`systemctl status nginx` if you SSH)
* **CloudWatch**: verify ASG metrics and scaling events
* **Logs**: EC2 system logs or `/var/log/nginx/access.log` to debug web requests

---

# Cost & cleanup warning

* ALB + EC2 instances + CloudWatch metrics may incur charges. Always `terraform destroy` or delete console resources after testing.
* Use small instance types (`t3.micro`) and low max sizes for testing.

---
