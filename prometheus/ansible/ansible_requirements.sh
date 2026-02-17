#!/usr/bin/env bash

set -eu

# static code analysis:
##   shellcheck ansible_requirements.sh

function link_ansible_role {
    existing_source_path="$1"
    symbolic_link_path="$2"
    symbolic_link_dir=$(dirname "${symbolic_link_path}")

    # If a symlink exists but doesn't match the source specified, remove it
    if [[ -L "${symbolic_link_path}" ]] && [ "$(readlink -- "${symbolic_link_path}")" = "${existing_source_path}" ]; then
        echo "existing symlink matches expected destination: ${existing_source_path}"
    else
        echo "existing symlink does not match, removing: ${symbolic_link_path}"
        rm -f "${symbolic_link_path}"
    fi

    # If the symlink doesn't exist create it
    if [[ -L "${symbolic_link_path}" ]]; then
        echo "symlink already exists"
    else
        echo "creating symlink: ${symbolic_link_path}"
        if [[ ! -d "${symbolic_link_dir}" ]]; then
            echo "creating symlink containing directory: ${symbolic_link_dir}"
            mkdir -p "${symbolic_link_dir}"
        fi
        ln -fs "${existing_source_path}" "${symbolic_link_path}"
    fi
}

# Change to the directory the script is in
pushd "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Where is the ansible_shared directory in relation to this directory
gitman_dependencies_path="../dependencies"
repo_root=$(git rev-parse --show-toplevel)



# Linking Individual Roles
# link_ansible_role "../${gitman_dependencies_path}/mttjohnson_infra/ansible/roles/xxxxx" "roles/xxxxx"

# Linking All Roles
# link_ansible_role "../${gitman_dependencies_path}/mttjohnson_infra/ansible/roles" "roles"

# Linking Collections from gitman dependencies
link_ansible_role "../../../${gitman_dependencies_path}/mttjohnson_infra/ansible" "collections/ansible_collections/mttjohnson/infra"

# Linking Collections from local path
# link_ansible_role "~/projects/infra-components/ansible" "collections/ansible_collections/mttjohnson/infra"

# Linking Collections from local path at the root of this repo
# link_ansible_role "${repo_root}/ansible_collection" "collections/ansible_collections/local/infra"



# Change back to the directory originally called from
popd