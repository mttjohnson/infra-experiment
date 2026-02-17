terraform {
  required_version = "1.11.2" # Also specified in .opentofu-version file for tenv use
  
  required_providers {
    incus = {
      source  = "lxc/incus"
      version = "~> 1.0" # https://registry.terraform.io/providers/lxc/incus/latest
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0" # https://registry.terraform.io/providers/cloudflare/cloudflare/latest
    }
    powerdns = {
      source  = "pan-net/powerdns"
      version = "~> 1.5" # https://registry.terraform.io/providers/pan-net/powerdns/latest
    }
  }
}
