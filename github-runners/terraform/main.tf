# The Hetzner Cloud server the GitHub Actions runners live on.
#
# Terraform only claims the machine: a stock image, the admin SSH key and a
# firewall. NixOS replaces the image afterwards (../README.md), so nothing here
# knows about the runners.
#
# The API token comes from the HCLOUD_TOKEN environment variable, never from a
# file in this public repository.

terraform {
  required_version = ">= 1.9"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.70"
    }
  }

  # The storage account TableTab's Terraform keeps its state in, with a
  # container per repository. Access is through `az login`.
  backend "azurerm" {
    resource_group_name  = "infrastructure"
    storage_account_name = "tabletapinfra"
    container_name       = "personal-automation"
    key                  = "github-runners.tfstate"
  }
}

provider "hcloud" {}

variable "server_type" {
  description = "Hetzner server type. The CX line is shared Intel/AMD, EU locations only."
  type        = string
  default     = "cx33"
}

variable "location" {
  description = "Hetzner location. CX stock differs per location, so this is the knob to turn when one is sold out: nbg1, fsn1 or hel1."
  type        = string
  default     = "nbg1"
}

# Hetzner refuses the same public key twice in one project, and another stack
# may already have uploaded the admin key, so it is found by its content here
# rather than created.
data "hcloud_ssh_keys" "uploaded" {}

locals {
  admin_public_key = trimspace(file("${path.module}/../nixos/admin.pub"))
  admin_key_ids    = [for key in data.hcloud_ssh_keys.uploaded.ssh_keys : tostring(key.id) if startswith(key.public_key, local.admin_public_key)]
}

# Runners only dial out. Docker publishes container ports past the host
# firewall, so this one, outside the machine, is what keeps a job from exposing
# a port to the internet.
resource "hcloud_firewall" "runner" {
  name = "github-runner"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "runner" {
  name         = "github-runner"
  server_type  = var.server_type
  location     = var.location
  image        = "ubuntu-24.04"
  ssh_keys     = local.admin_key_ids
  firewall_ids = [hcloud_firewall.runner.id]

  # The image and the key are only what the NixOS installer boots from and logs
  # in with. Hetzner keeps reporting both after NixOS has replaced them, and a
  # change to either must never rebuild a machine that is running jobs.
  lifecycle {
    ignore_changes = [image, ssh_keys]

    precondition {
      condition     = length(local.admin_key_ids) == 1
      error_message = "The key in ../nixos/admin.pub is not uploaded to this Hetzner project. Add it in the Hetzner Console under Security, SSH keys, then apply again."
    }
  }
}

# The one disk a reinstall or a replaced server leaves alone. It holds what must
# outlive the system, which today is the runners' GitHub token (../README.md).
# NixOS formats it once and mounts it. A volume cannot change location, and
# Terraform refuses to destroy this one.
resource "hcloud_volume" "persist" {
  name              = "github-runner-persist"
  size              = 10
  location          = var.location
  delete_protection = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "hcloud_volume_attachment" "persist" {
  volume_id = hcloud_volume.persist.id
  server_id = hcloud_server.runner.id
  automount = false
}

output "ipv4" {
  description = "Public IPv4 address of the runner server."
  value       = hcloud_server.runner.ipv4_address
}

output "ipv6" {
  description = "Public IPv6 address of the runner server."
  value       = hcloud_server.runner.ipv6_address
}
