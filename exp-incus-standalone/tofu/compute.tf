# Lookup username that ssh uses (username form environment) and
# return results as JSON encoded map of string keys and string values
# TODO: consider refactoring to use Terraform native support for environment
# variables instead of shelling out to call jq
data "external" "get_local_username" {
  # The external provider requires every result value to be a string, so coalesce
  # unset env vars to "" (a null would error). ssh_auth_sock is used below to
  # decide whether an ssh-agent is available for the remote-exec connection.
  program = ["jq", "-n", "env | {username: (.USER // \"\"), ssh_auth_sock: (.SSH_AUTH_SOCK // \"\")}"]
}

data "local_file" "cloud_init_ssh_key_pub" {
  filename = pathexpand(var.cloud_init_ssh_key_pub_path)
}

locals {
  # An ssh-agent is available when SSH_AUTH_SOCK is set in the environment.
  ssh_agent_available = data.external.get_local_username.result["ssh_auth_sock"] != ""

  # Choose the SSH auth method per environment without editing code or tfvars:
  #   * if an ssh-agent is running (encrypted key unlocked via the agent), so leave
  #     private_key unset and let the communicator use the agent.
  #   * if no ssh-agent is running, use the configured unencrypted, access-scoped key file.
  # Using the key requires both no agent and a key path that points to a real file.
  remote_connection_use_private_key = (
    !local.ssh_agent_available &&
    var.remote_connection_ssh_private_key_path != "" &&
    fileexists(pathexpand(var.remote_connection_ssh_private_key_path))
  )
}

resource "incus_instance" "system" {
  for_each = { for r in var.instances_metadata : r.hostname => r }

  name = each.value.hostname

  # https://linuxcontainers.org/incus/docs/main/howto/images_remote/
  image     = var.incus_image_name
  type      = var.incus_instance_type
  profiles  = ["default"]
  ephemeral = false

  # https://linuxcontainers.org/incus/docs/main/reference/instance_options/
  config = {

    # https://linuxcontainers.org/incus/docs/main/reference/instance_options/#resource-limits
    "limits.cpu"    = each.value.vcpu
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
        "packages" : [
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
    # Render the per-instance network-config: an explicit network_config
    # override wins; otherwise render templates/netcfg-<network_profile>.yaml.tftpl
    # so the structure can vary by machine type (container vs virtual-machine).
    "cloud-init.network-config" = coalesce(
      each.value.network_config,
      templatefile(
        "${path.module}/templates/netcfg-${each.value.network_profile}.yaml.tftpl",
        {
          ip_address = each.value.ip_address
          gateway    = var.static_net_gateway
          dns        = var.static_net_dns
          dns_search = ["hc.deney.io", "local"]
        }
      )
    )
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
    properties = merge(
      {
        # path required for container attached filesystem
        # path needs to be ommitted on virtual-machine attached block device
        pool   = "local"
        source = incus_storage_volume.data[each.value.hostname].name
      },
      incus_storage_volume.data[each.value.hostname].content_type == "filesystem" ? { path = var.incus_attached_container_data_storage_path } : {}
    )
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

    # Remote connection settings. private_key wins when a key file is configured
    # and present; otherwise private_key is null and the SSH communicator falls
    # back to ssh-agent (SSH_AUTH_SOCK). See local.remote_connection_use_private_key.
    connection {
      type        = "ssh"
      user        = data.external.get_local_username.result["username"]
      host        = each.value.ip_address
      private_key = local.remote_connection_use_private_key ? file(pathexpand(var.remote_connection_ssh_private_key_path)) : null
      agent       = local.remote_connection_use_private_key ? false : true
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

  name = "${each.value.hostname}-data"
  pool = "local"
  type = "custom"
  # content_type needs to be filesystem for attaching to container instances
  # content_type needs to be block for attaching to virtual-machine instances
  content_type = var.incus_storage_volume_content_type
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
                fq_hostname = "${hostname}.${var.power_dns_zone}"
                ansible_host = lookup(
                  { for r in var.instances_metadata : r.hostname => r.ip_address },
                  hostname,
                  null
                )
                attached_data_disk_type = var.incus_storage_volume_content_type
                static_ipv4_to_use = lookup(
                  { for r in var.instances_metadata : r.hostname => r.ip_address },
                  hostname,
                  null
                )
                net_default_gateway         = var.static_net_gateway
                net_dns                     = var.static_net_dns
                additional_disk_device_path = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_incus_data"
                acme_dns_reg_cert_domains = [
                  for obj in var.acme_dns_domains_to_register :
                  obj.fq_domain if obj.hostname == hostname
                ]
                certbot_domains = [
                  for obj in var.certbot_domains :
                  obj.fq_domain if obj.hostname == hostname
                ]
                acme_dns_replicate_registration = [
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
    interpreter = ["/bin/bash", "-c"]
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
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOF
      source ansible_pre_exec.sh
      ansible-playbook playbooks/system.yml
    EOF
  }
}
