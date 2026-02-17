output "ssh_command" {
  value = <<EOF
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR ${incus_instance.system.ipv4_address != "" ? incus_instance.system.ipv4_address : ""}
ssh ${incus_instance.system.name}
EOF
}
