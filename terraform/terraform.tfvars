aws_region      = "us-east-1"
key_name        = "my-keypair"          # optional if you want SSH
allowed_ssh_cidr = "203.0.113.4/32"     # your IP address
instance_type   = "t3.micro"
min_size        = 1
max_size        = 2
desired_capacity = 1
