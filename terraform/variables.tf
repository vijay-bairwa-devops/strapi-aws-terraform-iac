variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  type    = string
  default = "strapi-project"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "ssh_key_name" {
  description = "Name of an existing EC2 Key Pair in AWS (for SSH access). Create/import one if you don't have it."
  type        = string
}

variable "git_repo" {
  description = "Git clone URL for your Strapi repo (HTTPS or SSH)."
  type        = string
}

variable "db_password" {
  description = "Postgres password for RDS (use secure secret in real world or Secrets Manager)."
  type        = string
  sensitive   = true
}

variable "db_username" {
  type    = string
  default = "strapi"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

