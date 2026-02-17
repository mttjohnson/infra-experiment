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

variable "instance_name" {
  type = string
}

variable "cloudflare_zone_domain" {
  type = string
}
variable "cloudflare_zone_id" {
  type = string
}

variable "acme_dns_domains_to_register" {
  type = list(object({
    domain_record_name = string
    fq_domain          = string
  }))
  default = [
    {
      domain_record_name = "hostname",
      fq_domain          = "hostname.example.com",
    },
  ]
}

variable "pdns_server_url" {
  type = string
}
variable "power_dns_zone" {
  type = string
}

variable "static_ipv4_address" {
  type = string
}
variable "static_net_gateway" {
  type = string
}
variable "static_net_dns" {
  type = string
}
