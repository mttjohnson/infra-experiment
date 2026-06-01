
# Get the contents of the files from the acme-dns registration events
data "local_file" "acme_dns_registrations" {
  # depends_on = [
  #   null_resource.system_provisioning_pre_initialization,
  # ]
  # for_each = { for d in var.acme_dns_domains_to_register : d.fq_domain => d }
  for_each = { for d in var.acme_dns_domains_to_register : "${d.hostname}-${d.fq_domain}" => d }
  filename = "../../ansible/acme-dns-registrations/${each.value.fq_domain}"
}

# Create CNAME acme magic dns records pointing to the registered acme-dns record for each registered domain
resource "cloudflare_dns_record" "dns_records" {
  depends_on = [
    data.local_file.acme_dns_registrations,
  ]

  # for_each = { for d in var.acme_dns_domains_to_register : d.fq_domain => d }
  for_each = { for d in var.acme_dns_domains_to_register : "${d.hostname}-${d.fq_domain}" => d }

  zone_id = var.cloudflare_zone_id
  name    = "_acme-challenge.${each.value.domain_record_name}"
  content = trimspace(data.local_file.acme_dns_registrations["${each.value.hostname}-${each.value.fq_domain}"].content)
  type    = "CNAME"
  ttl     = 300 # 5 min
  comment = "assistant to the requestor"
}

# Create A record in local private DNS server
resource "powerdns_record" "record_list" {
  for_each = { for r in var.power_dns_records : "${r.hostname}" => r }

  zone    = "${var.power_dns_zone}."
  name    = "${each.value.hostname}.${var.power_dns_zone}."
  type    = each.value.type
  ttl     = each.value.ttl
  records = each.value.records
}
