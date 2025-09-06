variable "aws_region" { type = string; default = "us-east-1" }
variable "key_name" { type = string; default = "" } # set your key pair name if SSH required
variable "instance_type" { type = string; default = "t3.micro" }
variable "min_size" { type = number; default = 1 }
variable "max_size" { type = number; default = 2 }
variable "desired_capacity" { type = number; default = 1 }
variable "allowed_ssh_cidr" { type = string; default = "0.0.0.0/0" } # restrict in prod
