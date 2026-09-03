# Unit 4 - Cloud Computing and DevOps  -  OTHM K/650/7997
# Artefact P4.5   Assessment criteria: AC 2.1, 2.3, 2.4
# Terraform - VPC, subnets, NACLs and security groups
# 
# Vera Cree  |  Candidate 240301062  |  CIPS Centre DC2401845

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
  backend "s3" { # remote state, locked, encrypted
    bucket         = "skyforge-tfstate"
    key            = "platform/prod.tfstate"
    region         = "eu-west-2"
    dynamodb_table = "skyforge-tflock"
    encrypt        = true
  }
}

# ---------------- NETWORK ----------------
resource "aws_vpc" "main" {
  cidr_block           = "10.30.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "skyforge-prod", Environment = "production" }
}

resource "aws_subnet" "public" {
  for_each          = { a = "10.30.1.0/24", b = "10.30.2.0/24" }
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = "eu-west-2${each.key}"
  tags              = { Name = "public-${each.key}", "kubernetes.io/role/elb" = "1" }
}

resource "aws_subnet" "app" { # private - EKS worker nodes
  for_each          = { a = "10.30.11.0/24", b = "10.30.12.0/24" }
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = "eu-west-2${each.key}"
  tags              = { Name = "app-${each.key}", "kubernetes.io/role/internal-elb" = "1" }
}

resource "aws_subnet" "data" { # private - NO route to any gateway
  for_each          = { a = "10.30.21.0/24", b = "10.30.22.0/24" }
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = "eu-west-2${each.key}"
  tags              = { Name = "data-${each.key}" }
}

# ---------------- NACL: stateless subnet boundary ----------------
resource "aws_network_acl" "data" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [for s in aws_subnet.data : s.id]

  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "10.30.11.0/24"
    from_port  = 5432
    to_port    = 5432
  }

  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "10.30.12.0/24"
    from_port  = 5432
    to_port    = 5432
  }

  # Ephemeral ports, so that replies to outbound connections are permitted.
  # A NACL is stateless: unlike a security group it does not track state.
  ingress {
    rule_no    = 200
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "10.30.0.0/16"
    from_port  = 1024
    to_port    = 65535
  }

  egress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "10.30.0.0/16"
    from_port  = 1024
    to_port    = 65535
  }

  # The implicit final rule denies everything else in both directions.
  tags = { Name = "data-tier-nacl" }
}

# ---------------- SECURITY GROUPS: stateful host boundary ----------------
#
# The three tiers reference one another - ALB forwards to app, app connects to
# the database, and each accepts traffic only from the tier above it. Written
# as INLINE ingress/egress blocks, those references make the groups mutually
# dependent and Terraform rejects the configuration:
#
#     Error: Cycle: aws_security_group.db, aws_security_group.alb,
#                   aws_security_group.app
#
# The groups are therefore declared with no inline rules, and every rule is a
# separate resource. Rules depend on groups, groups depend only on the VPC, so
# the graph is acyclic. This is the pattern AWS documents for tiered designs.
#
# Inline rules and standalone rule resources must never be mixed on the same
# group: each considers itself authoritative and they revoke one another on
# every apply. All rules below are therefore standalone, including the ones
# that do not cross-reference a group.

resource "aws_security_group" "alb" {
  name        = "skyforge-alb"
  description = "Edge - public HTTPS termination"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "skyforge-alb", Tier = "edge" }
}

resource "aws_security_group" "app" {
  name        = "skyforge-app"
  description = "Application tier - reachable from the load balancer only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "skyforge-app", Tier = "application" }
}

resource "aws_security_group" "db" {
  name        = "skyforge-db"
  description = "Data tier - reachable from the application tier only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "skyforge-db", Tier = "data" }
}

# ---- Edge -------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "alb_https_in" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to the application tier only"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

# ---- Application ------------------------------------------------------
# Referencing the ALB's security group rather than a CIDR means the rule stays
# correct if the load balancer is rebuilt on different addresses.
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Application traffic from the load balancer only"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

# Accepted risk, reviewed 28 Aug 2026. Trivy AWS-0104 rates unrestricted
# egress CRITICAL. The rule is deliberate: the application tier needs outbound
# HTTPS to the AWS control plane, package mirrors, and third-party payment and
# identity providers, whose address ranges are large and change without notice.
# Pinning CIDRs here would fail closed at the worst possible moment.
#
# Compensating controls: egress is confined to 443/tcp; the tier sits in
# private subnets reachable only via the NAT gateway; and the data tier has no
# egress rule and no gateway route at all.
#
# Improvement path, not yet implemented: VPC interface endpoints for S3, ECR,
# Secrets Manager and CloudWatch would take most of this traffic off the
# internet path and allow the rule to be narrowed to the remaining third parties.
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "app_https_out" {
  security_group_id = aws_security_group.app.id
  description       = "Outbound HTTPS via the NAT gateway"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL to the data tier"
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

# ---- Data -------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the application tier only"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

# No egress rule is declared for the data tier: the database initiates no
# outbound connection, so there is nothing to allow.
#
# Worth stating precisely, because "no egress rule in the configuration" and
# "no egress from the instance" are not the same thing. EC2 attaches a default
# allow-all egress rule to every new security group. The old inline form
# suppressed it as a side effect of declaring other egress blocks; with
# standalone rules there is no such side effect, so the default would survive.
# The data-tier subnets carry no route to the NAT or internet gateway (see the
# route tables above) and the data-tier NACL denies outbound at the subnet
# boundary, so egress is closed by routing and by NACL regardless. To close it
# at the group as well, import the default rule and destroy it, or attach an
# empty-egress group; that is a deliberate operational step and is recorded in
# the runbook rather than being implied here.
