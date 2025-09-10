**“AWS Application Load Balancer (ALB) with Auto Scaling Group (ASG)”** in two parts:

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
  
8. **Load Testing for Auto Scaling**

   * To demonstrate Auto Scaling in action, we generate artificial CPU load on the EC2 instances.
     This triggers the Target Tracking Scaling Policy (based on average CPU utilization) and causes the Auto Scaling Group to scale up.
     ### Steps
     1. SSH into one of the running EC2 instances in the Auto Scaling Group:
     ```bash
     ssh -i <your-key>.pem ubuntu@<public-ip-of-instance>
     ```

     2. [Upload or create the CPU stress script. Example Python script](cpu_stress.py):
     ```python
     import multiprocessing
     import time
     
     def cpu_load():
         while True:
             pass
     
     if __name__ == "__main__":
         for _ in range(multiprocessing.cpu_count()):
             p = multiprocessing.Process(target=cpu_load)
             p.start()
         time.sleep(600)  # run for 10 minutes
     ```
     Run the script:
     ```bash
     python3 cpu_stress.py
     ```

     3. Monitor scaling events:
        AWS Console → EC2 → Auto Scaling Groups → Activity Or use CLI:
        ```bash
        aws autoscaling describe-scaling-activities --auto-scaling-group-name <asg-name>
        ```
     4. Once CPU load decreases (or after you terminate extra instances), the ASG will scale down.

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
[Terraform script: main.tf](main.tf)

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
