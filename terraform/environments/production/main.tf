locals {
  tags = { app = "salessphere-erp", env = "prod" }
}

resource "azurerm_resource_group" "erp" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_virtual_network" "erp" {
  name                = "vm-${var.suffix}VNET"
  resource_group_name = azurerm_resource_group.erp.name
  location            = azurerm_resource_group.erp.location
  address_space       = ["10.0.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "erp" {
  name                 = "vm-${var.suffix}Subnet"
  resource_group_name  = azurerm_resource_group.erp.name
  virtual_network_name = azurerm_virtual_network.erp.name
  address_prefixes     = ["10.0.0.0/24"]
}

resource "azurerm_network_security_group" "erp" {
  name                = "nsg-${var.suffix}"
  resource_group_name = azurerm_resource_group.erp.name
  location            = azurerm_resource_group.erp.location
}

resource "azurerm_network_security_rule" "inbound" {
  for_each = {
    ssh   = { priority = 100, port = "22" }
    http  = { priority = 110, port = "80" }
    https = { priority = 120, port = "443" }
  }
  name                        = "allow-${each.key}"
  resource_group_name         = azurerm_resource_group.erp.name
  network_security_group_name = azurerm_network_security_group.erp.name
  priority                    = each.value.priority
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = each.value.port
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

resource "azurerm_public_ip" "erp" {
  name                = "pip-${var.suffix}"
  resource_group_name = azurerm_resource_group.erp.name
  location            = azurerm_resource_group.erp.location
  allocation_method   = "Static"
  sku                 = "Standard"

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_network_interface" "erp" {
  name                = "vm-${var.suffix}VMNic"
  resource_group_name = azurerm_resource_group.erp.name
  location            = azurerm_resource_group.erp.location
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfigvm-${var.suffix}"
    subnet_id                     = azurerm_subnet.erp.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.erp.id
  }
}

resource "azurerm_network_interface_security_group_association" "erp" {
  network_interface_id      = azurerm_network_interface.erp.id
  network_security_group_id = azurerm_network_security_group.erp.id
}

resource "azurerm_linux_virtual_machine" "erp" {
  name                  = "vm-${var.suffix}"
  resource_group_name   = azurerm_resource_group.erp.name
  location              = azurerm_resource_group.erp.location
  size                  = var.vm_size
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.erp.id]
  secure_boot_enabled   = true
  vtpm_enabled          = true
  patch_mode            = "ImageDefault"
  patch_assessment_mode = "ImageDefault"
  tags                  = local.tags

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    name                 = var.os_disk_name
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_postgresql_flexible_server" "erp" {
  name                          = var.postgres_name
  resource_group_name           = azurerm_resource_group.erp.name
  location                      = azurerm_resource_group.erp.location
  version                       = "16"
  administrator_login           = "ssadmin"
  sku_name                      = "B_Standard_B1ms"
  storage_mb                    = 32768
  storage_tier                  = "P4"
  auto_grow_enabled             = false
  zone                          = "3"
  backup_retention_days         = 7
  geo_redundant_backup_enabled  = false
  public_network_access_enabled = true
  tags                          = local.tags

  authentication {
    active_directory_auth_enabled = false
    password_auth_enabled         = true
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_postgresql_flexible_server_database" "erp" {
  name      = "salessphere"
  server_id = azurerm_postgresql_flexible_server.erp.id
  charset   = "UTF8"
  collation = "en_US.utf8"

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_postgresql_flexible_server_database" "migrated" {
  count     = var.adopt_existing ? 1 : 0
  name      = "postgres"
  server_id = azurerm_postgresql_flexible_server.erp.id
  charset   = "UTF8"
  collation = "en_US.utf8"

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "existing" {
  for_each         = var.postgres_firewall_rules
  name             = each.key
  server_id        = azurerm_postgresql_flexible_server.erp.id
  start_ip_address = each.value.start_ip
  end_ip_address   = each.value.end_ip
}

output "server_host" {
  value = azurerm_public_ip.erp.ip_address
}

output "database_host" {
  value = azurerm_postgresql_flexible_server.erp.fqdn
}

output "application_database" {
  value = var.adopt_existing ? azurerm_postgresql_flexible_server_database.migrated[0].name : azurerm_postgresql_flexible_server_database.erp.name
}
