variable "infrastructure_tag" {
  type = string
}

variable "implementation_tag" {
  type = string
}

resource "random_id" "implementation" {
  byte_length = 3
}

variable "incus_image_name" {
  type = string
}

variable "incus_instance_type" {
  type    = string
  default = "container"

  # https://registry.terraform.io/providers/lxc/incus/latest/docs/resources/instance#type-1
  validation {
    condition     = contains(["container", "virtual-machine"], var.incus_instance_type)
    error_message = "The incus_instance_type must be either \"container\" or \"virtual-machine\"."
  }
}

variable "incus_storage_volume_content_type" {
  type    = string
  default = "block"

  # https://registry.terraform.io/providers/lxc/incus/latest/docs/resources/storage_volume#content_type-1
  validation {
    condition     = contains(["block", "filesystem"], var.incus_storage_volume_content_type)
    error_message = "The incus_storage_volume_content_type must be either \"block\" or \"filesystem\"."
  }
}

variable "incus_attached_container_data_storage_path" {
  type    = string
  default = "/data"
}

variable "remote_connection_ssh_private_key_path" {
  type = string
  # Leave empty to authenticate via ssh-agent instead of a key file. When set to
  # a path whose file exists, that (unencrypted) key is used directly. This lets
  # the same code use a scoped unencrypted key in the agent sandbox and the
  # encrypted, agent-unlocked key on the macOS operator workstation.
  default = ""
}

variable "cloud_init_ssh_key_pub_path" {
  type = string
}

variable "instances_metadata" {
  type = list(object({
    hostname     = string
    ip_address   = string
    vcpu         = number
    ram          = string
    sys_disk_sz  = string
    data_disk_sz = string
    # network_profile selects which templates/netcfg-<profile>.yaml.tftpl file
    # renders the cloud-init network-config (e.g. "container", "vm-bridge").
    network_profile = optional(string, "container")
    # network_config is an escape hatch: a fully-formed network-config YAML
    # string. When set it overrides the profile template entirely.
    network_config = optional(string)
  }))
  default = [
    {
      hostname     = "hostname",
      ip_address   = "127.0.0.1",
      vcpu         = 2,
      ram          = "1GiB",
      sys_disk_sz  = "10GiB",
      data_disk_sz = "10GiB",
    },
  ]
}
variable "static_net_gateway" {
  type = string
}
variable "static_net_dns" {
  type = string
}

variable "pdns_server_url" {
  type = string
}
variable "power_dns_zone" {
  type = string
}
variable "power_dns_records" {
  type = list(object({
    hostname = string
    type     = string
    ttl      = number
    records  = list(string)
  }))
  default = [
    {
      hostname = "hostname",
      type     = "A",
      ttl      = 300,
      records  = ["127.0.0.1"],
    },
  ]
}

variable "cloudflare_zone_domain" {
  type = string
}
variable "cloudflare_zone_id" {
  type = string
}

variable "acme_dns_domains_to_register" {
  type = list(object({
    hostname           = string
    domain_record_name = string
    fq_domain          = string
  }))
  default = [
    {
      hostname           = "hostname"
      domain_record_name = "hostname",
      fq_domain          = "hostname.example.com",
    },
  ]
}

variable "acme_dns_replicate_registration" {
  type = list(object({
    hostname    = string
    source_host = string
    fq_domain   = string
  }))
  default = [
    {
      hostname    = "hostname"
      source_host = "hostname",
      fq_domain   = "hostname.example.com",
    },
  ]
}

variable "certbot_domains" {
  type = list(object({
    hostname  = string
    fq_domain = string
  }))
  default = [
    {
      hostname  = "hostname"
      fq_domain = "hostname.example.com",
    },
  ]
}
