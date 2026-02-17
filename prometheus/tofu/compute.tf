# Lookup username that ssh uses (username form environment) and
# return results as JSON encoded map of string keys and string values
# TODO: consider refactoring to use Terraform native support for environment
# variables instead of shelling out to call jq
data "external" "get_local_username" {
  program = ["jq", "-n", "env | {username:.USER}"]
}

data "local_file" "cloud_init_ssh_key_pub" {
  filename = pathexpand(var.cloud_init_ssh_key_pub_path)
}

resource "incus_instance" "system" {
  for_each = { for r in var.instances_metadata : r.hostname => r }

  name = each.value.hostname

  # https://linuxcontainers.org/incus/docs/main/howto/images_remote/
  image     = var.incus_image_name
  type      = "container" # (container, virtual-machine)
  profiles  = ["default"]
  ephemeral = false

  # https://linuxcontainers.org/incus/docs/main/reference/instance_options/
  config = {

    # https://linuxcontainers.org/incus/docs/main/reference/instance_options/#resource-limits
    "limits.cpu" = each.value.vcpu
    "limits.memory" = each.value.ram

    "boot.autostart" = true
    # "cloud-init.user-data" = data.template_file.user_data.rendered
    "cloud-init.user-data" = join("\n", [
      "#cloud-config",
      # While this "#cloud-config" string looks like a comment, it appears
      # to be a required header for cloud-init to funciton properly
      # https://cloudinit.readthedocs.io/en/latest/reference/examples.html
      yamlencode({
        # Install any required packages on the server
        "packages": [
          "openssh-server" # Required for remote-exec provisioner and ansible
        ]
        "users" : [
          "default",
          {
            "name" : data.external.get_local_username.result["username"]
            "primary_group" : data.external.get_local_username.result["username"]
            "groups" : "users, admin"
            "shell" : "/bin/bash"
            "lock_passwd" : true
            "sudo" : "ALL=(ALL) NOPASSWD:ALL"
            "ssh_authorized_keys" : [
              data.local_file.cloud_init_ssh_key_pub.content
            ]
          }
        ]
      })
    ])
    "cloud-init.network-config" = <<-EOT
      network:
          version: 2
          ethernets:
              eth0:
                  dhcp4: false
                  dhcp6: false
                  addresses: [ ${each.value.ip_address}/24 ]
                  routes:
                    - to: default
                      via: ${var.static_net_gateway}
                  nameservers:
                    search: [ hc.deney.io, local ]
                    addresses: [ ${var.static_net_dns} ]
    EOT
  }

  device {
    type = "disk"
    name = "root"
    properties = {
      path = "/"
      pool = "local"
      size = each.value.sys_disk_sz
    }
  }

  device {
    type = "disk"
    name = "data"
    properties = {
      path   = "/data"
      pool   = "local"
      source = incus_storage_volume.data[each.value.hostname].name
    }
  }

  device {
    type = "nic" # https://linuxcontainers.org/incus/docs/main/reference/devices/
    name = "eth0"
    properties = {
      nictype = "bridged"
      parent  = "externalbr0"
      # "ipv4.address" = var.static_ipv4_address
    }
  }

  # Remote provisioner to ensure SSH is active
  # Wait for cloud-init to finish
  provisioner "remote-exec" {
    inline = ["/usr/bin/cloud-init status --format json --wait"]

    # Remote connection settings
    connection {
      type = "ssh"
      user = data.external.get_local_username.result["username"]
      host = each.value.ip_address
    }
  }

  lifecycle {
    ignore_changes = [
      # Ignore changes to config["cloud-init.user-data"], because after it is set the
      # first time it doesn't seem to be recognized even though it works, and then
      # afterwards terraform tries to keep adding it on every execution, and it's only
      # really needed here on the first call anyway.
      config["cloud-init.user-data"],
      config["cloud-init.network-config"],
    ]
  }
}

resource "incus_storage_volume" "data" {
  for_each = { for r in var.instances_metadata : r.hostname => r }

  name         = "${each.value.hostname}-data"
  pool         = "local"
  type         = "custom"
  content_type = "filesystem"
  config = {
    size = "${each.value.data_disk_sz}"
  }

  lifecycle {
    # prevent_destroy = true
    ignore_changes = [
      # If a custom storage volume is moved between incus hosts the 
      # zfs blocksize may not be recognized properly.
      config["zfs.blocksize"],
    ]
  }
}

resource "local_file" "system_ansible_inventory" {
  depends_on = [
    incus_instance.system
  ]

  content = replace(yamlencode(
    {
      all : {
        children : {
          "system" : {
            hosts : {
              for hostname, instance in incus_instance.system :
              instance.name => {
                fq_hostname                 = "${hostname}.${var.power_dns_zone}"
                ansible_host                = lookup(
                  { for r in var.instances_metadata : r.hostname => r.ip_address },
                  hostname,
                  null
                )
                static_ipv4_to_use          = lookup(
                  { for r in var.instances_metadata : r.hostname => r.ip_address },
                  hostname,
                  null
                )
                net_default_gateway         = var.static_net_gateway
                net_dns                     = var.static_net_dns
                additional_disk_device_path = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_incus_data"
                acme_dns_reg_cert_domains   = [
                  for obj in var.acme_dns_domains_to_register : 
                  obj.fq_domain if obj.hostname == hostname
                ]
                certbot_domains   = [
                  for obj in var.certbot_domains : 
                  obj.fq_domain if obj.hostname == hostname
                ]
                acme_dns_replicate_registration   = [
                  for obj in var.acme_dns_replicate_registration : 
                  { source_host = obj.source_host, domain = obj.fq_domain } if obj.hostname == hostname
                ]
              }
            }
          }
          tofu_vars : {
            children : {
              "system" : {}
            }
          }
        }
      }
    }
  ), "\"", "")
  filename = "../ansible/inventories/hosts.yml"
}

resource "null_resource" "system_provisioning_pre_initialization" {
  depends_on = [
    incus_instance.system,
    local_file.system_ansible_inventory,
    local_file.ansible_tofu_vars_file,
  ]

  triggers = {
    instance_ids = join(",", sort([
      for instance in incus_instance.system : instance.name
    ]))
  }

  # Run ansible acme_dns_register playbook
  provisioner "local-exec" {
    working_dir = "../ansible/"
    command     = <<EOF
      source ansible_pre_exec.sh
      ansible-playbook playbooks/acme_dns_register.yml
    EOF
  }
}

resource "null_resource" "system_provisioning_server_config" {
  depends_on = [
    null_resource.system_provisioning_pre_initialization,
  ]

  triggers = {
    instance_ids = join(",", sort([
      for instance in incus_instance.system : instance.name
    ]))
  }

  # Run ansible provisioning playbook
  provisioner "local-exec" {
    working_dir = "../ansible/"
    command     = <<EOF
      source ansible_pre_exec.sh
      ansible-playbook playbooks/system.yml
    EOF
  }
}
