# Unit 4 - Cloud Computing and DevOps  -  OTHM K/650/7997
# Artefact P4.6   Assessment criteria: AC 2.1, 2.2, 2.4
# Terraform - scalable and reliable EC2, S3 and RDS services
# 
# Vera Cree  |  Candidate 240301062  |  CIPS Centre DC2401845

# ---------------- COMPUTE: auto-scaling across two AZs ----------------
resource "aws_launch_template" "app" {
  name_prefix            = "skyforge-app-"
  image_id               = data.aws_ami.al2023.id
  instance_type          = "t3.medium"
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile { name = aws_iam_instance_profile.app.name }

  metadata_options { # IMDSv2 required - blocks SSRF
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = 30
      volume_type = "gp3"
      encrypted   = true
      kms_key_id  = aws_kms_key.platform.arn
    }
  }
  user_data = base64encode(file("${path.module}/../scripts/provision.sh"))
}

resource "aws_autoscaling_group" "app" {
  name                      = "skyforge-app-asg"
  vpc_zone_identifier       = [for s in aws_subnet.app : s.id] # spans 2 AZs
  min_size                  = 2                                # never single-homed
  max_size                  = 10
  desired_capacity          = 3
  health_check_type         = "ELB"
  health_check_grace_period = 120
  target_group_arns         = [aws_lb_target_group.app.arn]

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  # Zero-downtime rolling replacement when the launch template changes
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 66
    }
  }

  tag {
    key                 = "Name"
    value               = "skyforge-app"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "cpu" {
  name                   = "target-cpu-60"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification { predefined_metric_type = "ASGAverageCPUUtilization" }
    target_value = 60.0
  }
}

# ---------------- STORAGE: S3, private, versioned, encrypted ----------------
resource "aws_s3_bucket" "assets" { bucket = "skyforge-platform-assets-prod" }

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "assets" {
  bucket = aws_s3_bucket.assets.id
  versioning_configuration { status = "Enabled" } # ransomware / delete recovery
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.platform.arn
    }
    bucket_key_enabled = true # reduces KMS request cost
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id
  rule {
    id     = "tier-and-expire"
    status = "Enabled"

    # An empty filter applies the rule to every object in the bucket, which is
    # the intent. It has to be stated explicitly: a rule carrying neither
    # filter nor prefix is a provider warning today and an error from the next
    # major version.
    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

resource "aws_s3_bucket_policy" "assets_tls_only" {
  bucket = aws_s3_bucket.assets.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid = "DenyInsecureTransport", Effect = "Deny", Principal = "*"
      Action = "s3:*", Resource = ["${aws_s3_bucket.assets.arn}",
      "${aws_s3_bucket.assets.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# ---------------- DATABASE: Multi-AZ, encrypted, PITR ----------------
resource "aws_db_instance" "main" {
  identifier     = "skyforge-prod-db"
  engine         = "postgres"
  engine_version = "16.3"
  instance_class = "db.r6g.large"

  allocated_storage     = 100
  max_allocated_storage = 500 # storage autoscaling
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.platform.arn

  multi_az                  = true # synchronous standby, automatic failover
  backup_retention_period   = 30   # 30-day point-in-time recovery
  backup_window             = "02:00-03:00"
  maintenance_window        = "sun:03:30-sun:04:30"
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "skyforge-prod-final"

  db_subnet_group_name   = aws_db_subnet_group.data.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  performance_insights_enabled    = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  manage_master_user_password = true # credentials in Secrets Manager, rotated
}
