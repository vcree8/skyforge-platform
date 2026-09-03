# Unit 4 - Cloud Computing and DevOps  -  OTHM K/650/7997
# Artefact P4.5 (supporting)   Assessment criteria: AC 2.1, 2.2, 2.3
# Internet and NAT routing, and the public load balancer that fronts the
# application tier. Completes the network defined in network.tf.
#
# Vera Cree  |  Candidate 240301062  |  CIPS Centre DC2401845

# ---------------- INTERNET AND NAT EGRESS ----------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "skyforge-igw" }
}

resource "aws_eip" "nat" {
  for_each = aws_subnet.public
  domain   = "vpc"
  tags     = { Name = "skyforge-nat-${each.key}" }
}

# One NAT gateway per availability zone. A single shared NAT would be cheaper
# but becomes a zonal single point of failure for all outbound traffic.
resource "aws_nat_gateway" "main" {
  for_each      = aws_subnet.public
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = each.value.id
  depends_on    = [aws_internet_gateway.main]

  tags = { Name = "skyforge-nat-${each.key}" }
}

# ---------------- ROUTE TABLES ----------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "skyforge-public-rt" }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# App tier: outbound only, via the NAT gateway in its own AZ
resource "aws_route_table" "app" {
  for_each = aws_subnet.app
  vpc_id   = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[each.key].id
  }
  tags = { Name = "skyforge-app-rt-${each.key}" }
}

resource "aws_route_table_association" "app" {
  for_each       = aws_subnet.app
  subnet_id      = each.value.id
  route_table_id = aws_route_table.app[each.key].id
}

# Data tier: NO default route at all. The absence of a route to any gateway
# is what makes egress from the database subnet impossible by topology
# rather than by firewall rule.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "skyforge-data-rt-no-egress" }
}

resource "aws_route_table_association" "data" {
  for_each       = aws_subnet.data
  subnet_id      = each.value.id
  route_table_id = aws_route_table.data.id
}

# ---------------- APPLICATION LOAD BALANCER ----------------

# Accepted by design, reviewed 28 Aug 2026. Trivy AWS-0053 warns that a
# load balancer is internet-facing. That is the requirement: Skyforge is a
# customer-facing platform and this is its front door. The check exists to
# catch accidental exposure of internal assets, which this is not.
#
# What limits the exposure: the ALB security group admits only 443/tcp, TLS
# terminates here, invalid headers are dropped, deletion protection is on, and
# the only thing behind it is the application tier on port 8080 - the data tier
# is unreachable from this security group.
#trivy:ignore:AWS-0053
resource "aws_lb" "app" {
  name               = "skyforge-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.public : s.id]

  enable_deletion_protection = true
  drop_invalid_header_fields = true
  enable_http2               = true

  tags = { Name = "skyforge-alb", Environment = var.environment }
}

resource "aws_lb_target_group" "app" {
  name        = "skyforge-app-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/health/ready"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # Give in-flight requests time to complete before an instance is removed
  deregistration_delay = 30

  stickiness {
    type    = "lb_cookie"
    enabled = false
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.platform.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# All cleartext is redirected, never served
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ---------------- TLS CERTIFICATE ----------------

resource "aws_acm_certificate" "platform" {
  domain_name       = "platform.skyforge.io"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}
