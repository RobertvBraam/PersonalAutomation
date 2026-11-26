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

  # TODO: the state is a file on one machine, at the path given to
  # `terraform init -backend-config` (../README.md). Losing that machine means
  # importing the three resources again; a remote backend would remove that.
  backend "local" {}
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

resource "hcloud_ssh_key" "admin" {
  name       = "github-runner-admin"
  public_key = trimspace(file("${path.module}/../admin.pub"))
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
  ssh_keys     = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.runner.id]

  # The image is only what the NixOS installer boots from. Hetzner keeps
  # reporting it after NixOS has replaced it, and a new default must never
  # rebuild a machine that is running jobs.
  lifecycle {
    ignore_changes = [image, ssh_keys]
  }
}

output "ipv4" {
  description = "Public IPv4 address of the runner server."
  value       = hcloud_server.runner.ipv4_address
}

output "ipv6" {
  description = "Public IPv6 address of the runner server."
  value       = hcloud_server.runner.ipv6_address
}
