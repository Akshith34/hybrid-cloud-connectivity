###############################################################
# AWS Transit Gateway — Hub-and-Spoke Network Architecture
# Replaces point-to-point VPN mesh with centralized routing hub
###############################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "production"
}

variable "bgp_asn" {
  description = "BGP ASN for the Transit Gateway"
  type        = number
  default     = 64512
}

variable "on_premises_cidr" {
  description = "On-premises corporate network CIDR"
  type        = string
  default     = "10.0.0.0/8"
}

variable "spoke_vpcs" {
  description = "Map of spoke VPCs to attach to the TGW"
  type = map(object({
    vpc_id          = string
    subnet_ids      = list(string)
    cidr            = string
    route_table     = string # "finance" | "hr" | "shared"
  }))
}

##################################################
# Transit Gateway
##################################################

resource "aws_ec2_transit_gateway" "hub" {
  description                     = "Central hub for hybrid cloud connectivity"
  amazon_side_asn                 = var.bgp_asn
  auto_accept_shared_attachments  = "disable"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  vpn_ecmp_support                = "enable"
  dns_support                     = "enable"
  multicast_support               = "disable"

  tags = {
    Name        = "hybrid-cloud-tgw-hub"
    Environment = var.environment
    Purpose     = "hub-and-spoke connectivity"
    ManagedBy   = "terraform"
  }
}

##################################################
# TGW Route Tables (one per security domain)
##################################################

# Finance route table — isolated, only talks to shared services
resource "aws_ec2_transit_gateway_route_table" "finance" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id

  tags = {
    Name        = "tgw-rt-finance"
    Domain      = "finance"
    Environment = var.environment
  }
}

# HR route table — isolated from finance
resource "aws_ec2_transit_gateway_route_table" "hr" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id

  tags = {
    Name        = "tgw-rt-hr"
    Domain      = "hr"
    Environment = var.environment
  }
}

# Shared services route table — reachable from all spokes
resource "aws_ec2_transit_gateway_route_table" "shared" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id

  tags = {
    Name        = "tgw-rt-shared"
    Domain      = "shared-services"
    Environment = var.environment
  }
}

# On-premises route table — Direct Connect gateway attachment
resource "aws_ec2_transit_gateway_route_table" "on_premises" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id

  tags = {
    Name        = "tgw-rt-on-premises"
    Domain      = "on-premises"
    Environment = var.environment
  }
}

##################################################
# VPC Attachments — Spoke VPCs
##################################################

resource "aws_ec2_transit_gateway_vpc_attachment" "spokes" {
  for_each = var.spoke_vpcs

  transit_gateway_id                              = aws_ec2_transit_gateway.hub.id
  vpc_id                                          = each.value.vpc_id
  subnet_ids                                      = each.value.subnet_ids
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  dns_support                                     = "enable"
  ipv6_support                                    = "disable"

  tags = {
    Name        = "tgw-attach-${each.key}"
    VPC         = each.key
    Domain      = each.value.route_table
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

##################################################
# Route Table Associations
##################################################

resource "aws_ec2_transit_gateway_route_table_association" "finance" {
  for_each = {
    for k, v in var.spoke_vpcs : k => v
    if v.route_table == "finance"
  }

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spokes[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.finance.id
}

resource "aws_ec2_transit_gateway_route_table_association" "hr" {
  for_each = {
    for k, v in var.spoke_vpcs : k => v
    if v.route_table == "hr"
  }

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spokes[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hr.id
}

resource "aws_ec2_transit_gateway_route_table_association" "shared" {
  for_each = {
    for k, v in var.spoke_vpcs : k => v
    if v.route_table == "shared"
  }

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spokes[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared.id
}

##################################################
# Route Propagation — Shared services reachable from all
##################################################

resource "aws_ec2_transit_gateway_route_table_propagation" "shared_to_finance" {
  for_each = {
    for k, v in var.spoke_vpcs : k => v
    if v.route_table == "shared"
  }

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spokes[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.finance.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "shared_to_hr" {
  for_each = {
    for k, v in var.spoke_vpcs : k => v
    if v.route_table == "shared"
  }

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spokes[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hr.id
}

# On-premises route propagated to all route tables
resource "aws_ec2_transit_gateway_route" "on_premises_to_finance" {
  destination_cidr_block         = var.on_premises_cidr
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.finance.id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spokes["shared"].id
}

##################################################
# CloudWatch Monitoring
##################################################

resource "aws_cloudwatch_metric_alarm" "tgw_packet_drop" {
  alarm_name          = "tgw-packet-drop-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "PacketDropCountBlackhole"
  namespace           = "AWS/TransitGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = 100
  alarm_description   = "TGW dropping packets to blackhole — possible missing route"

  dimensions = {
    TransitGateway = aws_ec2_transit_gateway.hub.id
  }
}

resource "aws_cloudwatch_metric_alarm" "tgw_bytes_in" {
  alarm_name          = "tgw-bandwidth-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "BytesIn"
  namespace           = "AWS/TransitGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = 8000000000 # 8 GB per 5 min = ~200 Gbps sustained
  alarm_description   = "TGW bandwidth approaching limits"

  dimensions = {
    TransitGateway = aws_ec2_transit_gateway.hub.id
  }
}

##################################################
# Outputs
##################################################

output "transit_gateway_id" {
  value       = aws_ec2_transit_gateway.hub.id
  description = "Transit Gateway ID — use for VPC attachments and DX gateway association"
}

output "transit_gateway_arn" {
  value = aws_ec2_transit_gateway.hub.arn
}

output "finance_route_table_id" {
  value = aws_ec2_transit_gateway_route_table.finance.id
}

output "hr_route_table_id" {
  value = aws_ec2_transit_gateway_route_table.hr.id
}

output "shared_route_table_id" {
  value = aws_ec2_transit_gateway_route_table.shared.id
}

output "on_premises_route_table_id" {
  value = aws_ec2_transit_gateway_route_table.on_premises.id
}
