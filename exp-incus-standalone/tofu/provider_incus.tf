# Configure the Incus provider
provider "incus" {
  # Incus client library looks in ~/.config/incus for client.crt and client.key for authentication

  # default_remote = "tauro"

  # remote {
  #   name    = "tauro"
  #   address = "https://tauro.hc.deney.io"
  # }

  default_remote = "rauru"

  remote {
    name    = "rauru"
    address = "https://rauru.hc.deney.io"
  }

}
