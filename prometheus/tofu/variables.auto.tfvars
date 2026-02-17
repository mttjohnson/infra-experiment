# The infrastructure tag used in tracking resource usage on the account
infrastructure_tag = "experiment"

# The implementation tag is used to track the specific part of the infrastructre being implemented
implementation_tag = "prometheus"

# Incus Images
# https://images.linuxcontainers.org
# ubuntu	noble	amd64	cloud
incus_image_name = "images:ubuntu/noble/cloud/amd64"

# Instance SSH Access
cloud_init_ssh_key_pub_path = "~/.ssh/id_ed25519.pub"

instance_name = "prometheus"
power_dns_zone = "hc.deney.io"

cloudflare_zone_domain = "deney.io"                         # 754fba9a7cd7a3b7be24dc381d47c636
cloudflare_zone_id     = "754fba9a7cd7a3b7be24dc381d47c636" # deney.io

acme_dns_domains_to_register = [
  {
    domain_record_name = "prometheus.hc",
    fq_domain          = "prometheus.hc.deney.io",
  },
]

pdns_server_url = "http://10.10.30.3/"

static_ipv4_address = "10.10.30.11"
static_net_gateway  = "10.10.30.1"
static_net_dns      = "10.10.30.3"
