terraform {
  required_version = ">= 1.10"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }

    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.113"
      # Resolved 0.113.1 on first init. .terraform.lock.hcl pins by hash,
      # which is stronger than this constraint alone — commit it.
    }
  }

  backend "s3" {
    endpoints                   = { s3 = "http://nas.rookery.internal:8333" }
    bucket                      = "tofu-state"
    key                         = "homelab/infra.tfstate"
    region                      = "us-east-1"
    use_path_style              = true
    use_lockfile                = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }

  # State holds every value the provider touched, including the Proxmox API
  # token, in plaintext unless this block exists. `enforced = true` means an
  # unencrypted write is refused rather than silently permitted — the concrete
  # reason this build is on OpenTofu rather than Terraform.
  encryption {
    key_provider "pbkdf2" "state_key" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "encrypt" {
      keys = key_provider.pbkdf2.state_key
    }

    state {
      method   = method.aes_gcm.encrypt
      enforced = true
    }

    plan {
      method   = method.aes_gcm.encrypt
      enforced = true
    }
  }
}
