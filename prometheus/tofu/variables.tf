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
# Custom storage volumes attached to instances, used for NFS-backed backup
# storage. The volume is created in a pre-existing pool (managed on the Incus
# host, e.g. the shared `nas_lab_backup` dir pool) and mounted at mount_path.
# Incus creates the backing directory, so no host SSH or pre-created path is
# required.
variable "backup_volumes" {
  type = list(object({
    hostname    = string
    device_name = string
    pool        = string
    volume_name = string
    mount_path  = string
  }))
  default = []
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
