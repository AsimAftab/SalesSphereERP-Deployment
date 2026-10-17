locals {
  resource_group_id = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}"
  adoption          = var.adopt_existing ? toset(["existing"]) : toset([])
}

import {
  for_each = local.adoption
  to       = azurerm_resource_group.erp
  id       = local.resource_group_id
}

import {
  for_each = local.adoption
  to       = azurerm_virtual_network.erp
  id       = "${local.resource_group_id}/providers/Microsoft.Network/virtualNetworks/vm-${var.suffix}VNET"
}

import {
  for_each = local.adoption
  to       = azurerm_subnet.erp
  id       = "${local.resource_group_id}/providers/Microsoft.Network/virtualNetworks/vm-${var.suffix}VNET/subnets/vm-${var.suffix}Subnet"
}

import {
  for_each = local.adoption
  to       = azurerm_network_security_group.erp
  id       = "${local.resource_group_id}/providers/Microsoft.Network/networkSecurityGroups/nsg-${var.suffix}"
}

import {
  for_each = var.adopt_existing ? toset(["ssh", "http", "https"]) : toset([])
  to       = azurerm_network_security_rule.inbound[each.key]
  id       = "${local.resource_group_id}/providers/Microsoft.Network/networkSecurityGroups/nsg-${var.suffix}/securityRules/allow-${each.key}"
}

import {
  for_each = local.adoption
  to       = azurerm_public_ip.erp
  id       = "${local.resource_group_id}/providers/Microsoft.Network/publicIPAddresses/pip-${var.suffix}"
}

import {
  for_each = local.adoption
  to       = azurerm_network_interface.erp
  id       = "${local.resource_group_id}/providers/Microsoft.Network/networkInterfaces/vm-${var.suffix}VMNic"
}

import {
  for_each = local.adoption
  to       = azurerm_network_interface_security_group_association.erp
  id       = "${local.resource_group_id}/providers/Microsoft.Network/networkInterfaces/vm-${var.suffix}VMNic|${local.resource_group_id}/providers/Microsoft.Network/networkSecurityGroups/nsg-${var.suffix}"
}

import {
  for_each = local.adoption
  to       = azurerm_linux_virtual_machine.erp
  id       = "${local.resource_group_id}/providers/Microsoft.Compute/virtualMachines/vm-${var.suffix}"
}

import {
  for_each = local.adoption
  to       = azurerm_postgresql_flexible_server.erp
  id       = "${local.resource_group_id}/providers/Microsoft.DBforPostgreSQL/flexibleServers/${var.postgres_name}"
}

import {
  for_each = local.adoption
  to       = azurerm_postgresql_flexible_server_database.erp
  id       = "${local.resource_group_id}/providers/Microsoft.DBforPostgreSQL/flexibleServers/${var.postgres_name}/databases/salessphere"
}

import {
  for_each = var.adopt_existing ? var.postgres_firewall_rules : {}
  to       = azurerm_postgresql_flexible_server_firewall_rule.existing[each.key]
  id       = "${local.resource_group_id}/providers/Microsoft.DBforPostgreSQL/flexibleServers/${var.postgres_name}/firewallRules/${each.key}"
}

import {
  for_each = local.adoption
  to       = azurerm_postgresql_flexible_server_database.migrated[0]
  id       = "${local.resource_group_id}/providers/Microsoft.DBforPostgreSQL/flexibleServers/${var.postgres_name}/databases/postgres"
}
