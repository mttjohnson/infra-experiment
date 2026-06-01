
resource "local_file" "ansible_tofu_vars_file" {
  content = yamlencode(
    {
      infrastructure_tag    = "${var.infrastructure_tag}"
      implementation_tag    = "${var.implementation_tag}"
      iac_implementation_id = "${random_id.implementation.hex}"
    }
  )
  filename = "../ansible/inventories/group_vars/tofu_vars.yml"
}
