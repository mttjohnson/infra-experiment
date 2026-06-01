# Ansible

Loading the defined Ansible version

```bash
source ansible_pre_exec.sh
ansible --version
```

Installing/Updating PipEnv Ansible

```bash
pipenv --rm
pyenv install 3.14.2
pipenv --python "3.14.2" install
pipenv shell
ansible --version

pipenv --rm
pipenv sync
source "$(pipenv --venv)/bin/activate"
ansible --version
```

To leave a pipenv shell that has been activated

```bash
deactivate
```

Running a playbook

```bash
ansible-playbook playbooks/host.yml --diff --check
```
