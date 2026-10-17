variable "subscription_id" {
  type    = string
  default = "dbc92609-fae7-45fd-8a98-b89d39828cd4"
}

variable "resource_group_name" {
  type    = string
  default = "rg-salessphere-erp-prod-eastasia"
}

variable "location" {
  type    = string
  default = "eastasia"
}

variable "suffix" {
  type    = string
  default = "salessphere-erp"
}

variable "admin_ssh_public_key" {
  type        = string
  description = "Public SSH key only. Use TF_VAR_admin_ssh_public_key; never supply a private key."
  validation {
    condition     = can(regex("^ssh-(ed25519|rsa) ", var.admin_ssh_public_key))
    error_message = "An OpenSSH public key is required."
  }
}

variable "vm_size" {
  type    = string
  default = "Standard_B2als_v2"
}

variable "os_disk_name" {
  type    = string
  default = "vm-salessphere-erp_OsDisk_1_2e0b4bd3fc3e4715aef8dfa6f362b922"
}

variable "postgres_name" {
  type    = string
  default = "psql-salessphere-erp-ea"
}

variable "postgres_admin_password" {
  type        = string
  sensitive   = true
  ephemeral   = true
  default     = null
  description = "Fresh environments only: write-only password, never persisted in state or plans. Leave null on import."
}

variable "postgres_password_version" {
  type        = number
  default     = 0
  description = "Fresh environments only: set to 1 with the ephemeral password. Do not set during adoption."
}

variable "postgres_firewall_rules" {
  type = map(object({
    start_ip = string
    end_ip   = string
  }))
  description = "Existing rules preserved by explicit user request. The all-IPv4 rule is not a recommended fresh-environment default."
  default = {
    "FirewallIPAddress_2026-10-7_23-52-19" = { start_ip = "52.184.100.204", end_ip = "52.184.100.204" }
    "AllowAll_2026-10-8_13-47-53"          = { start_ip = "0.0.0.0", end_ip = "255.255.255.255" }
    "ClientIPAddress_2026-10-8_13-47-59"   = { start_ip = "167.220.238.212", end_ip = "167.220.238.212" }
  }
}

variable "adopt_existing" {
  type        = bool
  default     = true
  description = "Set false with fresh-environment overrides; imports must never point at another environment."
}
