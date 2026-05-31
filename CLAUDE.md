# Claude Code Instructions

## Ansible

### Running playbooks (CHECK MODE ONLY)

**The agent must only ever run playbooks in check mode (`--check`). Do not apply
changes.** The operator is not ready to delegate real applies — every playbook run you
make is for *validating* role changes, never for changing the remote system. A plain run
(without `--check`) is off-limits unless the operator explicitly asks for it in that
message. When in doubt, run `--check` and report what *would* change; let the operator
decide whether to apply.

Playbooks run inside a pipenv-managed virtualenv that pins the correct Ansible version.
A human gets this automatically: the implementation's `ansible/.envrc` triggers direnv on
`cd`, which runs `pipenv sync` and activates the venv. **direnv does not fire in the
agent's non-interactive shell**, so you must activate the environment yourself, in the
*same* shell invocation as the playbook (shell state does not persist between Bash calls).

Source `ansible_pre_exec.sh` — it does `pipenv sync`, activates the venv, and installs
Galaxy requirements (equivalent to what `.envrc` does, plus log rotation and requirements):

```bash
cd <implementation>/ansible            # e.g. agent-sandbox/ansible
source ansible_pre_exec.sh && \
  ansible-playbook playbooks/system.yml --diff --check
```

Useful flags:
- `--check` — **required**; dry run, applies nothing.
- `--diff` — show what would change; pair with `--check` to read the would-be edits.
- `--tags <role>` — scope the run to the role you are iterating on (e.g.
  `--tags bot_dev`) for a fast feedback loop.

A clean idempotent result is `changed=0` in the PLAY RECAP. If a task reports `changed`
on a converged system, that is a bug to fix (often a non-idempotent task), not noise to
ignore.

### Inspect effective inventory variables before running

Before running (or reasoning about) a play, review the variables that will actually be in
effect for the target host. Do **not** hand-reconcile the inventory file, `group_vars/`,
and `host_vars/` by reading each and guessing precedence — let Ansible compute the merge.
The `<tool>_user` defaults a role declares are frequently overridden in `group_vars`, so a
role default read in isolation is misleading (e.g. the agent-CLI roles default to a
placeholder user, but `group_vars/system.yml` sets `<tool>_user: "{{ bot_dev_user }}"`).

Source the venv first (`ansible_pre_exec.sh`), then from the implementation's `ansible/`
directory:

```bash
ansible-inventory --host <host>       # JSON of all merged vars for one host (precedence applied)
ansible-inventory --graph --vars      # group/host tree, showing which group each var rides on
ansible-inventory --list              # everything, all hosts and groups
```

**Caveats — what this does *not* show:**
- It resolves **inventory sources only** (inventory file + `group_vars/` + `host_vars/`).
  It does **not** include role `defaults`/`vars`, play `vars`, `set_fact`, or `-e`
  extra-vars. A variable that exists *only* as a role default will be **absent** here — so
  absence in this output means "role default wins," not "unset."
- Jinja values are shown **unrendered** (e.g. `{{ bot_dev_user }}`, not `sandy`). To see
  fully rendered runtime values including role defaults, add a transient
  `ansible.builtin.debug: var=hostvars[inventory_hostname]` task, or run with `--check -v`.

### Check mode compatibility
Playbooks must always be runnable with `--check` before applying to a remote system.
Check mode is the operator's safety gate: it must surface what would change and catch
errors before any real changes are made. A partial apply that leaves a system in a broken
intermediate state is worse than failing fast in check mode.

**Never use `when: not ansible_check_mode` to hide tasks.** Hiding tasks from check mode
defeats the entire purpose: errors that would occur during a real run are concealed instead
of surfaced early. The operator gets a false green check run, then hits failures mid-apply.

Use the correct pattern for each case:

- **`command` / `shell` tasks that are read-only** (e.g. querying an installed version):
  add `check_mode: false` and `changed_when: false`. These modules do not declare check
  mode support so Ansible skips them during a dry run — without `check_mode: false` the
  registered variable will be undefined and downstream tasks that depend on it will fail.

  **Caution:** `check_mode: false` forces the task to actually execute on the remote system
  during a dry run. This is only acceptable when the command is purely read-only and cannot
  alter state. A command like `node_exporter --version` just prints output and is safe. A
  command that writes files, modifies configuration, restarts processes, or produces any
  side effect is not — it would silently mutate the remote system when the operator expects
  `--check` to change nothing. Carefully review every `command` / `shell` task marked with
  `check_mode: false` to verify the command has no side effects.
- **Tasks that may fail in check mode** because a prior step was only simulated (unarchive
  on a not-yet-downloaded file, copy from a not-yet-extracted path, commands against a
  not-yet-installed binary): add `ignore_errors: "{{ ansible_check_mode }}"` so check mode
  shows the task would run without aborting the play.
- **Pure variable tasks** (`set_fact`, `debug`): no guard needed — they have no side
  effects and must run so downstream tasks have the data they need.
- **`stat`, `slurp`, GET-only `uri`, and other read-only modules**: no guard needed.
  These modules declare check mode support and run normally during a dry run already.
  Adding `check_mode: false` to them is redundant.
- **Tasks that modify state** (copy, template, service, package, etc.): no guard needed;
  let Ansible simulate them normally. Never add `check_mode: false` to these.

### Collection path resolution
Prefer `inventory_dir` over `playbook_dir` for constructing paths. When roles are invoked
via `ansible.builtin.import_playbook` from inside a collection, Ansible rewrites
`playbook_dir` to the collection's internal path, making it useless for pointing at files
in the user's project.

## TODO

- [ ] **Hooks** — Set up post-edit hooks to auto-run `yamllint` / `ansible-lint` on changed
      YAML files. Linter key reordering has silently dropped edits in past sessions; catching
      this immediately at edit time would prevent the need for redos.

- [ ] **Custom `/role` skill** — Create a skill that encodes Ansible role conventions:
      `listen`-based handlers (no `block` syntax), check-mode safety rules, `inventory_dir`
      path resolution, linting, and README variable table updates. Would eliminate repeated
      correction rounds at the start of Ansible sessions.

- [ ] **Molecule test-first workflow** — Explore having Claude write Molecule scenarios
      before implementing role changes: idempotency, check-mode produces no side effects,
      handler execution order, and compatibility across Python 3.11–3.14. Iterate on role
      code until all scenarios pass green before considering the feature done.
