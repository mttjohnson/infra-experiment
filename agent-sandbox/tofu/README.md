# OpenTofu

Setup DNS first (which requires extra privileges with external systems)
```bash
pushd dns

# Load Cloudflare API key
source ~/bin/load_cloudflare_api_token.sh
source ~/bin/load_powerdns_api_token.sh

tofu --version
tofu init
tofu validate
tofu fmt
tofu plan
tofu apply

popd
```

Setup the compute instance
```bash
tofu --version
tofu init
tofu validate
tofu fmt
tofu plan
tofu apply
```
