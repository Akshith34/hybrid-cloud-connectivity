###############################################################
# AWS Direct Connect — Dedicated Private Circuit
# Dual redundant 10 Gbps connections for 99.99% HA
###############################################################

variable "environment" {
  type    = string
  default = "production"
}

variable "dx_location_primary" {
  description = "Direct Connect facility location (primary)"
  type        = string
  default     = "EqDC2" # Equinix DC2 — Washington DC
}

variable "dx_location_secondary" {
  description = "Direct Connect facility location (secondary — different building)"
  type        = string
  default     = "CORESITE-RESTON" # CoreSite Reston — geographic diversity
}

variable "bandwidth" {
  description = "Direct Connect port speed"
  type        = string
  default     = "10Gbps"
}

variable "transit_gateway_id" {
  description = "TGW ID to associate with DX Gateway"
  type        = string
}

variable "on_premises_bgp_asn" {
  description = "BGP ASN of on-premises router"
  type        = number
  default     = 65000
}

variable "aws_bgp_asn" {
  description = "BGP ASN for AWS side"
  type        = number
  default     = 64512
}

variable "on_premises_cidrs" {
  description = "List of on-premises CIDRs to allow into AWS"
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "alarm_sns_arn" {
  description = "SNS ARN for connectivity alerts"
  type        = string
}

##################################################
# Direct Connect Gateway
# Associates with TGW for multi-VPC/multi-account access
##################################################

resource "aws_dx_gateway" "main" {
  name            = "hybrid-cloud-dx-gateway"
  amazon_side_asn = var.aws_bgp_asn

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_dx_gateway_association" "tgw" {
  dx_gateway_id         = aws_dx_gateway.main.id
  associated_gateway_id = var.transit_gateway_id

  allowed_prefixes = var.on_premises_cidrs
}

##################################################
# Primary Direct Connect Connection
##################################################

resource "aws_dx_connection" "primary" {
  name      = "dx-primary-${var.dx_location_primary}"
  bandwidth = var.bandwidth
  location  = var.dx_location_primary

  tags = {
    Name        = "dx-primary"
    Role        = "primary-circuit"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  lifecycle {
    prevent_destroy = true
  }
}

##################################################
# Secondary Direct Connect Connection (redundant)
# Different physical location for geographic diversity
##################################################

resource "aws_dx_connection" "secondary" {
  name      = "dx-secondary-${var.dx_location_secondary}"
  bandwidth = var.bandwidth
  location  = var.dx_location_secondary

  tags = {
    Name        = "dx-secondary"
    Role        = "redundant-circuit"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  lifecycle {
    prevent_destroy = true
  }
}

##################################################
# Transit Virtual Interfaces
# Connects DX to TGW for multi-VPC routing
##################################################

resource "aws_dx_transit_virtual_interface" "primary" {
  connection_id    = aws_dx_connection.primary.id
  name             = "transit-vif-primary"
  vlan             = 100
  address_family   = "ipv4"
  bgp_asn          = var.on_premises_bgp_asn
  amazon_address   = "169.254.10.1/30"
  customer_address = "169.254.10.2/30"
  bgp_auth_key     = var.bgp_auth_key_primary # stored in Secrets Manager
  dx_gateway_id    = aws_dx_gateway.main.id

  tags = {
    Name        = "transit-vif-primary"
    Circuit     = "primary"
    Environment = var.environment
  }
}

resource "aws_dx_transit_virtual_interface" "secondary" {
  connection_id    = aws_dx_connection.secondary.id
  name             = "transit-vif-secondary"
  vlan             = 200
  address_family   = "ipv4"
  bgp_asn          = var.on_premises_bgp_asn
  amazon_address   = "169.254.20.1/30"
  customer_address = "169.254.20.2/30"
  bgp_auth_key     = var.bgp_auth_key_secondary
  dx_gateway_id    = aws_dx_gateway.main.id

  tags = {
    Name        = "transit-vif-secondary"
    Circuit     = "secondary"
    Environment = var.environment
  }
}

variable "bgp_auth_key_primary" {
  description = "BGP MD5 auth key for primary VIF (from Secrets Manager)"
  type        = string
  sensitive   = true
}

variable "bgp_auth_key_secondary" {
  description = "BGP MD5 auth key for secondary VIF (from Secrets Manager)"
  type        = string
  sensitive   = true
}

##################################################
# CloudWatch Alarms — Circuit Health Monitoring
##################################################

resource "aws_cloudwatch_metric_alarm" "dx_connection_state_primary" {
  alarm_name          = "dx-primary-connection-down"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ConnectionState"
  namespace           = "AWS/DX"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "CRITICAL: Primary Direct Connect circuit is DOWN — traffic failing over to secondary"
  alarm_actions       = [var.alarm_sns_arn]
  ok_actions          = [var.alarm_sns_arn]
  treat_missing_data  = "breaching"

  dimensions = {
    ConnectionId = aws_dx_connection.primary.id
  }
}

resource "aws_cloudwatch_metric_alarm" "dx_connection_state_secondary" {
  alarm_name          = "dx-secondary-connection-down"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ConnectionState"
  namespace           = "AWS/DX"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "WARNING: Secondary Direct Connect circuit is DOWN — no redundancy available"
  alarm_actions       = [var.alarm_sns_arn]
  ok_actions          = [var.alarm_sns_arn]
  treat_missing_data  = "breaching"

  dimensions = {
    ConnectionId = aws_dx_connection.secondary.id
  }
}

resource "aws_cloudwatch_metric_alarm" "dx_bgp_state_primary" {
  alarm_name          = "dx-primary-bgp-session-down"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "VirtualInterfaceBpsIngress"
  namespace           = "AWS/DX"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Primary BGP session appears down — no ingress traffic detected"
  alarm_actions       = [var.alarm_sns_arn]
  treat_missing_data  = "breaching"

  dimensions = {
    VirtualInterfaceId = aws_dx_transit_virtual_interface.primary.id
  }
}

resource "aws_cloudwatch_metric_alarm" "dx_bandwidth_utilization" {
  alarm_name          = "dx-bandwidth-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "VirtualInterfaceBpsEgress"
  namespace           = "AWS/DX"
  period              = 300
  statistic           = "Average"
  threshold           = 8000000000 # 8 Gbps = 80% of 10 Gbps link
  alarm_description   = "Direct Connect bandwidth utilization exceeding 80% — consider capacity upgrade"
  alarm_actions       = [var.alarm_sns_arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    VirtualInterfaceId = aws_dx_transit_virtual_interface.primary.id
  }
}

##################################################
# Outputs
##################################################

output "dx_gateway_id" {
  value       = aws_dx_gateway.main.id
  description = "Direct Connect Gateway ID"
}

output "primary_connection_id" {
  value       = aws_dx_connection.primary.id
  description = "Primary DX connection ID"
}

output "secondary_connection_id" {
  value       = aws_dx_connection.secondary.id
  description = "Secondary (redundant) DX connection ID"
}

output "primary_vif_id" {
  value       = aws_dx_transit_virtual_interface.primary.id
  description = "Primary Transit VIF ID"
}

output "secondary_vif_id" {
  value       = aws_dx_transit_virtual_interface.secondary.id
  description = "Secondary Transit VIF ID"
}
