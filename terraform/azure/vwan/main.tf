###############################################################
# Azure Virtual WAN — Hub-and-Spoke for Azure + On-Premises
# Standard tier with ExpressRoute gateway integration
###############################################################

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

variable "resource_group_name" {
  type    = string
  default = "rg-hybrid-cloud-connectivity"
}

variable "environment" {
  type    = string
  default = "production"
}

variable "primary_location" {
  type    = string
  default = "East US"
}

variable "secondary_location" {
  type    = string
  default = "West US 2"
}

variable "hub_address_prefix_primary" {
  description = "Address space for primary vWAN hub"
  type        = string
  default     = "192.168.0.0/23"
}

variable "hub_address_prefix_secondary" {
  description = "Address space for secondary vWAN hub"
  type        = string
  default     = "192.168.2.0/23"
}

variable "spoke_vnets" {
  description = "Map of spoke VNets to connect to vWAN"
  type = map(object({
    vnet_id  = string
    location = string
  }))
}

##################################################
# Resource Group
##################################################

resource "azurerm_resource_group" "connectivity" {
  name     = var.resource_group_name
  location = var.primary_location

  tags = {
    Environment = var.environment
    Purpose     = "hybrid-cloud-connectivity"
    ManagedBy   = "terraform"
  }
}

##################################################
# Virtual WAN
##################################################

resource "azurerm_virtual_wan" "main" {
  name                = "vwan-hybrid-cloud"
  resource_group_name = azurerm_resource_group.connectivity.name
  location            = var.primary_location
  type                = "Standard" # Standard required for ExpressRoute + inter-hub routing

  allow_branch_to_branch_traffic = true
  disable_vpn_encryption         = false

  tags = {
    Name        = "vwan-hybrid-cloud"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

##################################################
# Virtual WAN Hubs
##################################################

resource "azurerm_virtual_hub" "primary" {
  name                = "vhub-eastus"
  resource_group_name = azurerm_resource_group.connectivity.name
  location            = var.primary_location
  virtual_wan_id      = azurerm_virtual_wan.main.id
  address_prefix      = var.hub_address_prefix_primary
  sku                 = "Standard"

  tags = {
    Name        = "vhub-eastus-primary"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "azurerm_virtual_hub" "secondary" {
  name                = "vhub-westus2"
  resource_group_name = azurerm_resource_group.connectivity.name
  location            = var.secondary_location
  virtual_wan_id      = azurerm_virtual_wan.main.id
  address_prefix      = var.hub_address_prefix_secondary
  sku                 = "Standard"

  tags = {
    Name        = "vhub-westus2-secondary"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

##################################################
# ExpressRoute Gateways (in each hub)
##################################################

resource "azurerm_express_route_gateway" "primary" {
  name                = "er-gw-eastus"
  resource_group_name = azurerm_resource_group.connectivity.name
  location            = var.primary_location
  virtual_hub_id      = azurerm_virtual_hub.primary.id
  scale_units         = 2 # 2 scale units = 4 Gbps, scales to 10 Gbps

  tags = {
    Name        = "er-gateway-primary"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "azurerm_express_route_gateway" "secondary" {
  name                = "er-gw-westus2"
  resource_group_name = azurerm_resource_group.connectivity.name
  location            = var.secondary_location
  virtual_hub_id      = azurerm_virtual_hub.secondary.id
  scale_units         = 1

  tags = {
    Name        = "er-gateway-secondary"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

##################################################
# VNet Connections to Primary Hub
##################################################

resource "azurerm_virtual_hub_connection" "spoke" {
  for_each = var.spoke_vnets

  name                      = "conn-${each.key}"
  virtual_hub_id            = azurerm_virtual_hub.primary.id
  remote_virtual_network_id = each.value.vnet_id

  routing {
    associated_route_table_id = azurerm_virtual_hub.primary.default_route_table_id

    propagated_route_table {
      route_table_ids = [azurerm_virtual_hub.primary.default_route_table_id]
      labels          = ["default"]
    }
  }
}

##################################################
# Hub Routing — Default Route Table
##################################################

resource "azurerm_virtual_hub_route_table" "default" {
  name           = "defaultRouteTable"
  virtual_hub_id = azurerm_virtual_hub.primary.id
  labels         = ["default"]

  route {
    name              = "route-to-on-premises"
    destinations_type = "CIDR"
    destinations      = ["10.0.0.0/8"]
    next_hop_type     = "ResourceId"
    next_hop          = azurerm_express_route_gateway.primary.id
  }
}

##################################################
# Outputs
##################################################

output "vwan_id" {
  value       = azurerm_virtual_wan.main.id
  description = "Virtual WAN resource ID"
}

output "primary_hub_id" {
  value       = azurerm_virtual_hub.primary.id
  description = "Primary vWAN hub resource ID"
}

output "secondary_hub_id" {
  value       = azurerm_virtual_hub.secondary.id
  description = "Secondary vWAN hub resource ID"
}

output "primary_er_gateway_id" {
  value       = azurerm_express_route_gateway.primary.id
  description = "Primary ExpressRoute gateway ID"
}

output "primary_hub_address_prefix" {
  value = azurerm_virtual_hub.primary.address_prefix
}
