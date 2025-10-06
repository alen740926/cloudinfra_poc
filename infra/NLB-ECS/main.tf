############################################
# variables.tf
############################################
variable "vpc_id"                  { type = string }
variable "private_subnet_ids"      { type = list(string) }
variable "public_subnet_ids"       { type = list(string) }
variable "app_name"                { type = string  default = "demo-app" }
variable "container_image"         { type = string  default = "public.ecr.aws/nginx/nginx:latest" }
variable "container_port"          { type = number  default = 80 }
variable "desired_count"           { type = number  default = 2 }
variable "enable_nlb_sg"           { type = bool    default = true } # requires newer provider

############################################
# provider pin (adjust to your environment)
############################################
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.50.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

############################################
# ECS cluster
############################################
resource "aws_ecs_cluster" "this" {
  name = "${var.app_name}-cluster"
}

############################################
# Security groups
############################################

# SG for ECS tasks (awsvpc)
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.app_name}-ecs-tasks-sg"
  description = "Allow traffic from NLB to ECS tasks"
  vpc_id      = var.vpc_id

  # Inbound from NLB to container_port
  ingress {
    protocol    = "tcp"
    from_port   = var.container_port
    to_port     = var.container_port
    # If you attach an SG to the NLB, reference it here; otherwise open from anywhere or CIDR
    security_groups = var.enable_nlb_sg ? [aws_security_group.nlb[0].id] : null
    cidr_blocks     = var.enable_nlb_sg ? null : ["0.0.0.0/0"]
  }

  # Egress to anywhere (task -> internet via NAT or VPC routes)
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Optional SG for NLB (supported if attached at create-time)
resource "aws_security_group" "nlb" {
  count       = var.enable_nlb_sg ? 1 : 0
  name        = "${var.app_name}-nlb-sg"
  description = "Restrict who can hit the NLB"
  vpc_id      = var.vpc_id

  # Allow inbound client traffic to the listener port(s)
  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"] # tighten to your CIDRs
  }

  # Allow outbound to tasks
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

############################################
# NLB
############################################
resource "aws_lb" "nlb" {
  name               = "${var.app_name}-nlb"
  load_balancer_type = "network"
  internal           = false
  subnets            = var.public_subnet_ids

  # Security groups for NLB (must be set on create; remove if provider doesn't support)
  dynamic "security_groups" {
    for_each = var.enable_nlb_sg ? [1] : []
    content  = [aws_security_group.nlb[0].id]
  }
}

# Target group (ip target type for Fargate)
resource "aws_lb_target_group" "nlb_tg" {
  name        = "${var.app_name}-tg"
  port        = var.container_port
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    protocol            = "TCP" # for L4 checks; if app speaks HTTP, prefer ALB with HTTP health checks
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }
}

resource "aws_lb_listener" "nlb_tcp" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_tg.arn
  }
}

############################################
# IAM for ECS task execution
############################################
data "aws_iam_policy_document" "task_exec_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "task_exec" {
  name               = "${var.app_name}-task-exec"
  assume_role_policy = data.aws_iam_policy_document.task_exec_assume.json
}
resource "aws_iam_role_policy_attachment" "task_exec" {
  role       = aws_iam_role.task_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

############################################
# Task definition (Fargate)
############################################
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.app_name}-td"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.task_exec.arn

  container_definitions = jsonencode([
    {
      name  = "app"
      image = var.container_image
      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]
    }
  ])
}

############################################
# ECS Service behind NLB
############################################
resource "aws_ecs_service" "svc" {
  name            = "${var.app_name}-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.nlb_tg.arn
    container_name   = "app"
    container_port   = var.container_port
  }

  lifecycle {
    ignore_changes = [desired_count] # allow external scaling
  }
}

############################################
# ECS "job" via EventBridge scheduled task
############################################
resource "aws_cloudwatch_event_rule" "job_schedule" {
  name                = "${var.app_name}-job-cron"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_iam_role" "events_invoke_ecs" {
  name = "${var.app_name}-events-ecs"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "events.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "events_invoke_ecs" {
  name = "${var.app_name}-events-ecs-policy"
  role = aws_iam_role.events_invoke_ecs.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = ["ecs:RunTask", "iam:PassRole"],
      Resource = ["*"]
    }]
  })
}

resource "aws_cloudwatch_event_target" "run_ecs_task" {
  rule      = aws_cloudwatch_event_rule.job_schedule.name
  target_id = "run-ecs-task"
  arn       = aws_ecs_cluster.this.arn
  role_arn  = aws_iam_role.events_invoke_ecs.arn

  ecs_target {
    task_definition_arn = aws_ecs_task_definition.app.arn
    launch_type         = "FARGATE"
    network_configuration {
      subnets         = var.private_subnet_ids
      security_groups = [aws_security_group.ecs_tasks.id]
      assign_public_ip = false
    }
  }
}

############################################
# OPTIONAL: WAF on ALB (pattern when you need WAF)
# - Create an ALB, attach WAF WebACL to the ALB
# - Make ALB a target of the NLB (ALB target type for NLB)
# This gives static IPs from NLB + WAF inspection at ALB.
# (Uncomment and complete as needed.)
############################################
# resource "aws_lb" "alb" {
#   name               = "${var.app_name}-alb"
#   load_balancer_type = "application"
#   internal           = false
#   subnets            = var.public_subnet_ids
#   security_groups    = [aws_security_group.nlb[0].id] # or a dedicated ALB SG
# }
#
# resource "aws_wafv2_web_acl" "web_acl" {
#   name        = "${var.app_name}-waf"
#   description = "WAF for ALB"
#   scope       = "REGIONAL"
#   default_action { allow {} }
#   visibility_config {
#     cloudwatch_metrics_enabled = true
#     metric_name                = "${var.app_name}-waf"
#     sampled_requests_enabled   = true
#   }
#   # Add managed rule groups here…
# }
#
# resource "aws_wafv2_web_acl_association" "alb_assoc" {
#   resource_arn = aws_lb.alb.arn
#   web_acl_arn  = aws_wafv2_web_acl.web_acl.arn
# }
#
# # Make ALB a target of the NLB (via ALB-type target group)
# resource "aws_lb_target_group" "nlb_to_alb" {
#   name        = "${var.app_name}-nlb-to-alb"
#   port        = 80
#   protocol    = "TCP"
#   vpc_id      = var.vpc_id
#   target_type = "alb"
# }
# resource "aws_lb_target_group_attachment" "attach_alb" {
#   target_group_arn = aws_lb_target_group.nlb_to_alb.arn
#   target_id        = aws_lb.alb.arn
# }
# # Then point the NLB listener default_action to aws_lb_target_group.nlb_to_alb.arn
