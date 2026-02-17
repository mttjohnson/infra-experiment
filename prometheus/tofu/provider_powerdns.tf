# Configure the PowerDNS provider
provider "powerdns" {
  server_url = "${var.pdns_server_url}"

  # use PDNS_API_KEY instead
  # load via: source ~/bin/load_cloudflare_api_token.sh
  # api_key = "xxxxx_powerdns_api_key_xxxxx"
}
