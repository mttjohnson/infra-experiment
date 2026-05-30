# The infrastructure tag used in tracking resource usage on the account
infrastructure_tag = "experiment"

# The implementation tag is used to track the specific part of the infrastructre being implemented
implementation_tag = "agent-sandbox"

# Incus Images
# https://images.linuxcontainers.org
# ubuntu	noble	amd64	cloud
incus_image_name = "images:ubuntu/resolute/cloud/amd64"

# Instance SSH Access
cloud_init_ssh_key_pub_path = "~/.ssh/id_ed25519.pub"

# Instances
instances_metadata = [
  { hostname = "agent-sandbox", ip_address = "10.10.30.13", vcpu = 4, ram = "4GiB", sys_disk_sz = "30GiB", data_disk_sz = "10GiB" },
]
static_net_gateway = "10.10.30.1"
static_net_dns     = "10.10.30.3"

# Local DNS
pdns_server_url = "http://10.10.30.3/"
power_dns_zone  = "hc.deney.io"
power_dns_records = [
  { hostname = "agent-sandbox", type = "A", ttl = 300, records = ["10.10.30.13"] },
]

# Public DNS / ACME DNS / Certbot Managed Certs
cloudflare_zone_domain = "deney.io"                         # 754fba9a7cd7a3b7be24dc381d47c636
cloudflare_zone_id     = "754fba9a7cd7a3b7be24dc381d47c636" # deney.io
acme_dns_domains_to_register = [
  # { hostname = "agent-sandbox", domain_record_name = "agent-sandbox.hc", fq_domain = "agent-sandbox.hc.deney.io" },
]
acme_dns_replicate_registration = []
certbot_domains = [
  # { hostname = "agent-sandbox", fq_domain = "agent-sandbox.hc.deney.io" },
]
