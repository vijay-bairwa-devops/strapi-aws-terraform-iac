resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags = { Name = "${var.project_name}-public-subnet" }
}

data "aws_availability_zones" "available" {}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "${var.project_name}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security groups
resource "aws_security_group" "alb_sg" {
  name   = "${var.project_name}-alb-sg"
  vpc_id = aws_vpc.main.id

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

resource "aws_security_group" "ec2_sg" {
  name   = "${var.project_name}-ec2-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 1337
    to_port         = 1337
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id] # only ALB -> EC2
    description     = "Allow ALB to reach Strapi (non-HTTPS for demo)."
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # change to your IP for better security
    description = "SSH access - restrict in production"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds_sg" {
  name   = "${var.project_name}-rds-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
    description     = "Allow EC2 to reach RDS Postgres"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# S3 bucket for uploads
resource "aws_s3_bucket" "uploads" {
  bucket = "${var.project_name}-uploads-${random_id.bucket_suffix.hex}"
  acl    = "private"
  force_destroy = true
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# IAM role & policy for EC2 to access S3
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ec2_role" {
  name               = "${var.project_name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_policy" "s3_access" {
  name = "${var.project_name}-s3-access"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = [aws_s3_bucket.uploads.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = ["${aws_s3_bucket.uploads.arn}/*"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_s3" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_access.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.ec2_role.name
}

# RDS Postgres
resource "aws_db_subnet_group" "default" {
  name       = "${var.project_name}-db-subnet"
  subnet_ids = [aws_subnet.public.id] # for demo, private recommended in prod
}

resource "aws_db_instance" "postgres" {
  allocated_storage    = var.db_allocated_storage
  engine               = "postgres"
  engine_version       = "15.3"
  instance_class       = "db.t3.micro"
  name                 = "strapi_db"
  username             = var.db_username
  password             = var.db_password
  skip_final_snapshot  = true
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  db_subnet_group_name = aws_db_subnet_group.default.name
  publicly_accessible  = true  # for demo only; restrict in production
}

# EC2 instance
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["137112412989","amazon"] # Amazon owner ids (varies); fallback
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2","amzn2-ami-*-x86_64*"]
  }
}

resource "aws_instance" "strapi" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  key_name               = var.ssh_key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    git_repo       = var.git_repo,
    db_host        = aws_db_instance.postgres.address,
    db_port        = aws_db_instance.postgres.port,
    db_name        = aws_db_instance.postgres.db_name,
    db_user        = var.db_username,
    db_password    = var.db_password,
    s3_bucket      = aws_s3_bucket.uploads.bucket
  })

  tags = { Name = "${var.project_name}-ec2" }
}

# ALB
resource "aws_lb" "alb" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = [aws_subnet.public.id]
  security_groups    = [aws_security_group.alb_sg.id]
}

resource "aws_lb_target_group" "tg" {
  name     = "${var.project_name}-tg"
  port     = 1337
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  health_check {
    path                = "/"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

resource "aws_lb_target_group_attachment" "att" {
  target_group_arn = aws_lb_target_group.tg.arn
  target_id        = aws_instance.strapi.id
  port             = 1337
}

# Outputs
output "alb_dns" {
  value = aws_lb.alb.dns_name
}
output "ec2_public_ip" {
  value = aws_instance.strapi.public_ip
}
output "rds_endpoint" {
  value = aws_db_instance.postgres.address
}

