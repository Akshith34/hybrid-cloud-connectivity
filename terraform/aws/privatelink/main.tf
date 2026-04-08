###############################################################
# AWS PrivateLink — VPC Endpoints for Private Service Access
# Keeps sensitive financial data off the public internet
###############################################################

variable "vpc_id" {
  description = "VPC ID to create endpoints in"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for interface endpoints"
  type        = list(string)
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "production"
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to use the endpoints (on-prem + VPCs)"
  type        = list(string)
  default     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
}

##################################################
# Security Group for Interface Endpoints
##################################################

resource "aws_security_group" "endpoints" {
  name        = "vpc-endpoints-sg"
  description = "Security group for VPC interface endpoints"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from private networks only"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "HTTP (redirect only)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "vpc-endpoints-sg"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

##################################################
# Gateway Endpoints (free — no hourly charge)
##################################################

# S3 Gateway Endpoint — keeps S3 traffic private
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  tags = {
    Name        = "endpoint-s3"
    Service     = "s3"
    Type        = "gateway"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# DynamoDB Gateway Endpoint
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"

  tags = {
    Name        = "endpoint-dynamodb"
    Service     = "dynamodb"
    Type        = "gateway"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

##################################################
# Interface Endpoints — Critical AWS Services
##################################################

locals {
  interface_endpoints = {
    "secretsmanager" = "com.amazonaws.${var.aws_region}.secretsmanager"
    "rds"            = "com.amazonaws.${var.aws_region}.rds"
    "kms"            = "com.amazonaws.${var.aws_region}.kms"
    "sts"            = "com.amazonaws.${var.aws_region}.sts"
    "ssm"            = "com.amazonaws.${var.aws_region}.ssm"
    "ssmmessages"    = "com.amazonaws.${var.aws_region}.ssmmessages"
    "ec2messages"    = "com.amazonaws.${var.aws_region}.ec2messages"
    "logs"           = "com.amazonaws.${var.aws_region}.logs"
    "monitoring"     = "com.amazonaws.${var.aws_region}.monitoring"
    "ecr-api"        = "com.amazonaws.${var.aws_region}.ecr.api"
    "ecr-dkr"        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = var.vpc_id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true # Auto-resolves service FQDNs to private IPs

  tags = {
    Name        = "endpoint-${each.key}"
    Service     = each.key
    Type        = "interface"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

##################################################
# Private DNS — Route 53 Resolver
# Ensures on-premises DNS resolves AWS service
# endpoints to private IPs (not public internet)
##################################################

resource "aws_route53_resolver_endpoint" "inbound" {
  name      = "hybrid-cloud-inbound-resolver"
  direction = "INBOUND"

  security_group_ids = [aws_security_group.endpoints.id]

  dynamic "ip_address" {
    for_each = var.subnet_ids
    content {
      subnet_id = ip_address.value
    }
  }

  tags = {
    Name        = "hybrid-cloud-inbound-resolver"
    Purpose     = "on-premises DNS resolution of AWS services"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_route53_resolver_endpoint" "outbound" {
  name      = "hybrid-cloud-outbound-resolver"
  direction = "OUTBOUND"

  security_group_ids = [aws_security_group.endpoints.id]

  dynamic "ip_address" {
    for_each = var.subnet_ids
    content {
      subnet_id = ip_address.value
    }
  }

  tags = {
    Name        = "hybrid-cloud-outbound-resolver"
    Purpose     = "forward on-premises domain queries to on-prem DNS"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Forward on-premises domain to corporate DNS servers
resource "aws_route53_resolver_rule" "on_premises_forward" {
  domain_name          = "corp.internal"
  name                 = "forward-to-on-premises-dns"
  rule_type            = "FORWARD"
  resolver_endpoint_id = aws_route53_resolver_endpoint.outbound.id

  target_ip {
    ip   = "10.0.0.2" # Primary on-premises DNS
    port = 53
  }

  target_ip {
    ip   = "10.0.0.3" # Secondary on-premises DNS
    port = 53
  }

  tags = {
    Name      = "forward-corp-internal"
    ManagedBy = "terraform"
  }
}

##################################################
# Outputs
##################################################

output "s3_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}

output "interface_endpoint_ids" {
  value = {
    for k, v in aws_vpc_endpoint.interface : k => v.id
  }
}

output "inbound_resolver_ips" {
  value       = aws_route53_resolver_endpoint.inbound.ip_address
  description = "IP addresses on-premises should send DNS queries to for AWS service resolution"
}

output "outbound_resolver_id" {
  value = aws_route53_resolver_endpoint.outbound.id
}
