terraform {
  required_version = "1.11.2" # Also specified in .opentofu-version file for tenv use

  required_providers {
    incus = {
      source  = "lxc/incus"
      version = "~> 1.0" # https://registry.terraform.io/providers/lxc/incus/latest
    }
  }
}
