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

# Instances
instances_metadata = [
  { hostname = "prometheus", ip_address = "10.10.30.11", vcpu = 2, ram = "2GiB", sys_disk_sz = "50GiB", data_disk_sz = "50GiB" },
]
static_net_gateway = "10.10.30.1"
static_net_dns     = "10.10.30.3"

# Backup storage volumes. Created in the shared `nas_lab_backup` dir pool that
# is set up on the Incus host (per-host source subtree). Incus creates the
# backing directory; the volume is mounted inside the instance at mount_path.
backup_volumes = [
  { hostname = "prometheus", device_name = "backups", pool = "nas_lab_backup", volume_name = "prometheus", mount_path = "/backups" },
]

# Local DNS
pdns_server_url = "http://10.10.30.3/"
power_dns_zone  = "hc.deney.io"
power_dns_records = [
  { hostname = "prometheus", type = "A", ttl = 300, records = ["10.10.30.11"] },
]

# Public DNS / ACME DNS / Certbot Managed Certs
cloudflare_zone_domain = "deney.io"                         # 754fba9a7cd7a3b7be24dc381d47c636
cloudflare_zone_id     = "754fba9a7cd7a3b7be24dc381d47c636" # deney.io
acme_dns_domains_to_register = [
  { hostname = "prometheus", domain_record_name = "prometheus.hc", fq_domain = "prometheus.hc.deney.io" },
]
acme_dns_replicate_registration = []
certbot_domains = [
  { hostname = "prometheus", fq_domain = "prometheus.hc.deney.io" },
]
