# The infrastructure tag used in tracking resource usage on the account
infrastructure_tag = "experiment"

# The implementation tag is used to track the specific part of the infrastructre being implemented
implementation_tag = "exp-incus-standalone"

# Incus Images
# https://images.linuxcontainers.org
# ubuntu	noble	amd64	cloud
incus_image_name                           = "images:ubuntu/jammy/cloud/amd64"
incus_instance_type                        = "virtual-machine"
incus_storage_volume_content_type          = "block"
incus_attached_container_data_storage_path = "/data"

# Instance SSH Access
remote_connection_ssh_private_key_path = "~/.ssh/id_ed25519"
cloud_init_ssh_key_pub_path            = "~/.ssh/id_ed25519.pub"

# Instances
instances_metadata = [
  { hostname = "exp-incus-standalone", ip_address = "10.10.30.16", vcpu = 2, ram = "3GiB", sys_disk_sz = "30GiB", data_disk_sz = "10GiB", network_profile = "vm-bridge" },
]
static_net_gateway = "10.10.30.1"
static_net_dns     = "10.10.30.3"

# Local DNS
pdns_server_url = "http://10.10.30.3/"
power_dns_zone  = "hc.deney.io"
power_dns_records = [
  { hostname = "exp-incus-standalone", type = "A", ttl = 300, records = ["10.10.30.16"] },
]

# Public DNS / ACME DNS / Certbot Managed Certs
cloudflare_zone_domain = "deney.io"                         # 754fba9a7cd7a3b7be24dc381d47c636
cloudflare_zone_id     = "754fba9a7cd7a3b7be24dc381d47c636" # deney.io
acme_dns_domains_to_register = [
  # { hostname = "exp-incus-standalone", domain_record_name = "exp-incus-standalone.hc", fq_domain = "exp-incus-standalone.hc.deney.io" },
]
acme_dns_replicate_registration = []
certbot_domains = [
  # { hostname = "exp-incus-standalone", fq_domain = "exp-incus-standalone.hc.deney.io" },
]
