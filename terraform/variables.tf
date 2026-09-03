# Unit 4 - Cloud Computing and DevOps  -  OTHM K/650/7997
# Artefact P4.5 / P4.6 (supporting)   Assessment criteria: AC 2.4
# Input variables and shared data sources for the Skyforge platform.
#
# Vera Cree  |  Candidate 240301062  |  CIPS Centre DC2401845

variable "aws_region" {
  description = "AWS region hosting the platform."
  type        = string
  default     = "eu-west-2"
}

variable "environment" {
  description = "Deployment environment. Drives naming and sizing."
  type        = string
  default     = "production"

  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "environment must be development, staging or production."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the platform VPC."
  type        = string
  default     = "10.30.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "app_instance_type" {
  description = "EC2 instance type for the application auto-scaling group."
  type        = string
  default     = "t3.medium"
}

variable "db_instance_class" {
  description = "RDS instance class. Multi-AZ doubles the cost of this choice."
  type        = string
  default     = "db.r6g.large"
}

variable "office_cidrs" {
  description = "Source ranges permitted to reach the EKS public endpoint."
  type        = list(string)
  default     = ["203.0.113.0/24"]
}

variable "backup_retention_days" {
  description = "RDS automated backup retention. Sets the point-in-time recovery window."
  type        = number
  default     = 30

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 7 and 35."
  }
}

# ---------------- SHARED DATA SOURCES ----------------

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------- ENCRYPTION KEY ----------------
# One customer-managed key covers EBS, S3, RDS and EKS secrets, so key
# rotation and access policy are managed in a single place.

resource "aws_kms_key" "platform" {
  description             = "Skyforge platform encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "platform" {
  name          = "alias/skyforge-platform"
  target_key_id = aws_kms_key.platform.key_id
}

# ---------------- SUPPORTING RESOURCES ----------------

resource "aws_db_subnet_group" "data" {
  name       = "skyforge-data-subnets"
  subnet_ids = [for s in aws_subnet.data : s.id]

  tags = { Name = "skyforge-data-subnets" }
}

resource "aws_iam_instance_profile" "app" {
  name = "skyforge-app-profile"
  role = aws_iam_role.app.name
}

resource "aws_iam_role" "app" {
  name = "skyforge-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ---------------- OUTPUTS ----------------

output "vpc_id" {
  description = "Platform VPC id."
  value       = aws_vpc.main.id
}

output "app_subnet_ids" {
  description = "Private subnets hosting the application tier."
  value       = [for s in aws_subnet.app : s.id]
}

output "database_endpoint" {
  description = "RDS writer endpoint."
  value       = aws_db_instance.main.endpoint
  sensitive   = true
}

output "kms_key_arn" {
  description = "ARN of the platform customer-managed key."
  value       = aws_kms_key.platform.arn
}
