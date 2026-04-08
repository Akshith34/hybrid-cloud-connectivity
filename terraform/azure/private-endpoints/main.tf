###############################################################
# Azure Private Endpoints — Keep Financial Data Off Internet
# Private DNS zones for automatic FQDN resolution
###############################################################

variable "resource_group_name" { type = string }
variable "location"            { type = string; default = "East US" }
variable "subnet_id"           { type = string }
variable "environment"         { type = string; default = "production" }
variable "vnet_id"             { type = string }

variable "storage_account_id"     { type = string }
variable "sql_server_id"          { type = string }
variable "key_vault_id"           { type = string }
variable "service_bus_namespace_id" { type = string }

##################################################
# Private Endpoints
##################################################

locals {
  private_endpoints = {
    "storage-blob" = {
      resource_id   = var.storage_account_id
      subresource   = ["blob"]
      dns_zone_name = "privatelink.blob.core.windows.net"
    }
    "storage-file" = {
      resource_id   = var.storage_account_id
      subresource   = ["file"]
      dns_zone_name = "privatelink.file.core.windows.net"
    }
    "sql-server" = {
      resource_id   = var.sql_server_id
      subresource   = ["sqlServer"]
      dns_zone_name = "privatelink.database.windows.net"
    }
    "key-vault" = {
      resource_id   = var.key_vault_id
      subresource   = ["vault"]
      dns_zone_name = "privatelink.vaultcore.azure.net"
    }
    "service-bus" = {
      resource_id   = var.service_bus_namespace_id
      subresource   = ["namespace"]
      dns_zone_name = "privatelink.servicebus.windows.net"
    }
  }
}

resource "azurerm_private_endpoint" "endpoints" {
  for_each = local.private_endpoints

  name                = "pe-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.subnet_id

  private_service_connection {
    name                           = "psc-${each.key}"
    private_connection_resource_id = each.value.resource_id
    subresource_names              = each.value.subresource
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-zone-group-${each.key}"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones[each.key].id]
  }

  tags = {
    Name        = "pe-${each.key}"
    Service     = each.key
    Environment = var.environment
    ManagedBy   = "terraform"
    Compliance  = "financial-data-sovereignty"
  }
}

##################################################
# Private DNS Zones
##################################################

resource "azurerm_private_dns_zone" "zones" {
  for_each = local.private_endpoints

  name                = each.value.dns_zone_name
  resource_group_name = var.resource_group_name

  tags = {
    Service     = each.key
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "links" {
  for_each = local.private_endpoints

  name                  = "link-${each.key}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.zones[each.key].name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

##################################################
# Outputs
##################################################

output "private_endpoint_ids" {
  value = {
    for k, v in azurerm_private_endpoint.endpoints : k => v.id
  }
}

output "private_endpoint_ips" {
  value = {
    for k, v in azurerm_private_endpoint.endpoints :
    k => v.private_service_connection[0].private_ip_address
  }
  description = "Private IP addresses assigned to each endpoint"
}

output "dns_zone_ids" {
  value = {
    for k, v in azurerm_private_dns_zone.zones : k => v.id
  }
}
