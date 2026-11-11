# Restic rebuild & recovery test runbook — prometheus

This runbook proves, on the real `prometheus` instance, that the backup/restore
recovery design behaves as intended: a rebuild either **restores** from backups
or **fails loudly and stays locked** — it never silently starts fresh, and never
lets retention or polluted backups erode the off-box copy.

The design being tested is documented in the restic role:
`ansible/collections/ansible_collections/mttjohnson/infra/roles/restic/RECOVERY.md`.

Tests run from least to most destructive. **Stop at the first unexpected result**
and investigate before continuing — a later test assumes every earlier one passed.

---

## 0. Open issues

Current limitations to keep in mind while testing.

| # | Severity | Issue | Effect on testing |
|---|---|---|---|
| 1 | Medium | `restic_failure_command` is unset, so a locked-out or failing job only shows in `journalctl` — nothing alerts you. The fail-closed lockout is only as loud as someone noticing it. | Test 1 shows this. Set a healthchecks-style command before relying on the lockout. |
| 2 | Low/Med | After a `/data` rebuild the local primary is re-initialized with fresh chunker params (not copied from the NAS), so `restic copy` dedups poorly. The new repo id also makes the write-once primary pin warn on every later run. There is no documented re-pin step yet. | Expect the primary repo-id **MISMATCH** warning on the run *after* Tests 7/9. Test 7 recommends rolling back for this reason. |
| 3 | Info | Tofu's provisioning `null_resource`s trigger on instance **names**, so replacing the instance with the same name does **not** re-run the playbooks. If a plan ever shows them being replaced, tofu runs a **real** `system.yml` apply with no check-mode preview. | Run the playbooks yourself after a tofu rebuild, check mode first. |

---

## Ground rules

- **Check mode first, every time.** Before each real apply, run the same command
  with `--check --diff`, compare the output to the test's **Expected (check)**, and
  only apply if it matches.
- **Move, never delete.** Every simulation moves things into a `*.pretest` location so
  you can roll back. Only delete those copies during final cleanup.
- **Protect the NAS first (step 0.3).** It's the last-resort copy, and the riskiest
  tests could add a bad snapshot to it if a bug exists.
- **Mind the schedule.** Backup runs at 02:00, copy 03:00, forget 03:30 (secondary
  03:45), prune Sun 04:00/04:30, each with up to 30 min random delay. Do destructive
  tests in daytime, and stop the timers during destructive steps. Timers are
  `Persistent=true`: if they're stopped across a scheduled time, restarting them
  (which the play does) fires the missed job **immediately**.
- **Keep evidence off the host.** Tests 8 and 9 wipe the root filesystem. Record
  baseline values in the results log on the control node, not on the instance.

---

## Reference

### Where things live

| What | Where |
|---|---|
| Control-node key (secret, git-ignored) | `prometheus/ansible/restic-state/prometheus.password` |
| Control-node pins (committed) | `restic-state/prometheus.{primary,secondary}.repo-id`, `restic-state/prometheus.volume.sentinel-id` |
| Host key / env | `/etc/restic/password`, `/etc/restic/env` (primary), `/etc/restic/env.secondary` |
| Blessed marker | `/etc/restic/blessed` (root disk) |
| Primary repo (local) | `/data/backups` on Incus volume `prometheus-data` (pool `local`) |
| Volume sentinel | `/data/.restic-volume-id` |
| Secondary repo (NAS) | `/backups` on Incus volume `prometheus` (pool `nas_lab_backup`) |
| Restore diagnostic markers | `/var/lib/restic_restore/<bundle>.json` |
| Tofu addresses | `incus_instance.system["prometheus"]`, `incus_storage_volume.data["prometheus"]`, `incus_storage_volume.backups["prometheus-backups"]` |

Recovery-critical bundles (`restore_required: true`): `letsencrypt`
(`/data/letsencrypt`), `prometheus` (`/data/prometheus`), `prometheus_basic_auth`
(`/root/prometheus_basic_auth_password.txt` + `_hash.txt`).

### Commands used throughout

**Control node**, from `prometheus/ansible` (direnv-activated shell):

```bash
# Check (always first)
ansible-playbook playbooks/system.yml --check --diff --tags restic,restic_restore

# Real apply, restic only
ansible-playbook playbooks/system.yml --diff --tags restic,restic_restore

# Full play (check first, then without --check)
ansible-playbook playbooks/system.yml --check --diff
```

**Host**, in a root shell (`sudo -i`). Load the primary repo's environment:

```bash
set -a
. /etc/restic/env
set +a
```

For the NAS repo, source `/etc/restic/env.secondary` instead. Then plain `restic …`
commands work. `/root/BACKUPS.md` on the host has more quick commands.

---

## Phase 0 — Pre-flight (non-destructive)

### 0.1 Take a fresh backup and replicate it

**What:** Run the backup and copy jobs now, then confirm both repos have the same
newest snapshot.

**Why:** Every restore test needs a known, recent restore point. It also proves the
backup → copy pipeline works end to end before you depend on it.

```bash
systemctl start restic-backup.service
systemctl start restic-copy.service
```

Then, with each env loaded in turn:

```bash
restic snapshots --latest 1
```

**Pass:** both commands succeed, and the newest snapshot in `/backups` has the same
`time` as the one in `/data/backups` (`restic copy` preserves it; IDs differ).

### 0.2 Record baseline evidence (off-host)

**What:** Capture the values that later prove a restore is faithful, not just
"present."

**Why:** Without a baseline, "it looks fine" is the only success criterion. These give
an objective pass/fail for each restored item.

Record each output in the results log:

| Item | Command (host, root) |
|---|---|
| Newest snapshot per repo | `restic snapshots --latest 1` (each env) |
| Repo ids vs pins | `restic cat config` (each env) — compare `id` with the `*.repo-id` files on the control node |
| Volume sentinel vs pin | `cat /data/.restic-volume-id` — compare with `restic-state/prometheus.volume.sentinel-id` |
| Basic-auth secrets | `sha256sum /root/prometheus_basic_auth_password.txt /root/prometheus_basic_auth_password_hash.txt` |
| Certificate | `openssl x509 -noout -fingerprint -sha256 -in /data/letsencrypt/live/prometheus.hc.deney.io/cert.pem` |
| TSDB blocks / size | `ls /data/prometheus` and `du -sh /data/prometheus` |
| Free space on /data | `df -h /data` |
| Blessed marker | `cat /etc/restic/blessed` |
| Prometheus uid | `id prometheus` (see the ownership watch item in Tests 8/9) |

### 0.3 Protect the NAS repository

**What:** Make an independent copy of the NAS repository that nothing in these tests
can touch.

**Why:** The NAS is the last-resort copy, and Tests 7 and 9 depend on it entirely. If
a bug adds a partial "newest" snapshot, or something goes wrong mid-test,
this copy is the way back.

Preferred: take a NAS-level snapshot of the share backing the `nas_lab_backup` pool
(for example a Synology Btrfs snapshot of the folder). Otherwise copy the repository
directory somewhere outside both the instance and that pool — a restic repo is plain
files, so a copy is a valid repo. Verify the copy: `restic -r <copy-path> snapshots`.

### 0.4 Verify the off-host password copy

**What:** Confirm the password in your password manager matches the control-node file.

**Why:** Tests 5 and 6 move the control-node key aside. If anything goes wrong there,
the password manager copy is the only remaining way to read any backup.

```bash
sha256sum restic-state/prometheus.password
```

Compare with a hash of the password-manager copy.

### 0.5 Baseline check run

**What:** Run the check command on the converged host.

**Why:** A clean baseline means any change in later tests is caused by the test.

**Expected:** `failed=0`, `changed=0`. No sentinel or repo-id warnings. All three
bundles report `SKIP (target already populated)`, and both "Unbless host before…" tasks
are skipped. Any change on a converged host is a real signal to investigate.

### 0.6 Clean git state

**What:** `git status` is clean, and the `restic-state/*.repo-id` and `*.sentinel-id`
pins are committed.

**Why:** Tests 4 and 7 can change pins; `git checkout` restores them exactly.

---

## Phase 1 — Gate and signal tests (in place, reversible)

### Test 1 — Fail-closed job gate (lockout)

**What it tests:** With no blessed marker, every state-changing job (backup, copy,
forget, prune — primary and secondary) refuses to run, while read-only checks still
run.

**Why it matters:** This is what protects your snapshots during an unresolved rebuild.
If it works, a failed recovery can't write polluting backups and can't run retention
against the NAS while you're away. It's also the one mechanism that must hold even
when nobody is watching the playbook output.

**Steps (host):**

```bash
systemctl stop 'restic-*.timer'
mv /etc/restic/blessed /root/blessed.pretest
systemctl start restic-backup.service
journalctl -u restic-backup.service -n 20 --no-pager
```

Repeat the last two lines for `restic-forget`, `restic-prune`, `restic-copy`,
`restic-forget-secondary`, and `restic-prune-secondary`. Then:

```bash
systemctl start restic-check.service
```

Re-run `restic snapshots` for both repos and compare the counts to 0.2.

**Expected:** each gated service fails with
`ERROR: /etc/restic/blessed absent — host is not blessed for backups`;
`restic-check` succeeds; snapshot counts are unchanged.

**Also note:** did anything alert you? With `restic_failure_command` unset (issue #1),
nothing will — a real lockout would only show in journald.

**Rollback:** continue to Test 2, which re-blesses the host. Afterwards:
`systemctl reset-failed 'restic-*'` and `rm /root/blessed.pretest`.

### Test 2 — The play re-blesses a healthy host

**What it tests:** On a healthy host with no marker, `restic_restore` writes the marker
again without manual help.

**Why it matters:** Recovery must end in a working backup schedule automatically.
Otherwise every rebuild needs a manual step that's easy to forget.

**Steps (control node):** check run, then real apply (restic tags).

**Expected (check):** "Bless host for backups (write blessed marker)" would change; no
failures or warnings.

**Expected (apply):** marker recreated; timers started again (changed — they were
stopped). `systemctl list-timers 'restic-*'` shows all ten timers scheduled.

### Test 2b — Restore-selection dry run (non-destructive)

**What it tests:** Every real bundle's selector resolves a snapshot, from which source,
and the host would be unblessed before the restore starts — without restoring anything.
It overrides the bundle list with the same three bundles, each with its restore target
relocated to an empty `/tmp` path so it looks unrestored. Check mode, so nothing is
written.

**Why it matters:** On a converged host every bundle is already populated, so normal
runs skip the snapshot query and can't tell you whether a rebuild would actually find
anything. A broken selector or query fails silently: bundles just report
`no matching snapshot`, which only bites during a real rebuild. Re-run this test whenever
you change backup paths, bundle selectors, or the restic version.

**Steps (control node):**

```bash
ansible-playbook playbooks/system.yml --check --tags restic,restic_restore -e '{"restic_restore_bundles":[{"name":"letsencrypt","paths":["/data/letsencrypt"],"snapshot_selector":{"paths":["/data/letsencrypt"]},"restore_required":true,"target":"/tmp/restore-dryrun"},{"name":"prometheus","paths":["/data/prometheus"],"snapshot_selector":{"paths":["/data/prometheus"]},"restore_required":true,"target":"/tmp/restore-dryrun"},{"name":"prometheus_basic_auth","paths":["/root/prometheus_basic_auth_password.txt","/root/prometheus_basic_auth_password_hash.txt"],"snapshot_selector":{"paths":["/root/prometheus_basic_auth_password.txt","/root/prometheus_basic_auth_password_hash.txt"]},"restore_required":true,"target":"/tmp/restore-dryrun"}]}'
```

Keep this bundle list in sync with `restic_restore_bundles` in `group_vars/system.yml`.

**Expected** (verified 2026-11-05): each bundle's plan summary shows a real snapshot (for
example `974c9eef @ 2026-11-05T02:12:26Z`), `chosen_source: primary` (the snapshot exists
in both repos, and ties go to the primary), and `action: RESTORE`. "Unbless host before
restoring" would change. There are no "would fail" warnings, and `failed=0`. Any bundle
showing `no matching snapshot` is a problem that would block real recovery — stop and
investigate.

### Test 3 — Wrong-volume detection (sentinel mismatch)

**What it tests:** If a different volume is mounted at `/data`, the role refuses to
operate before touching anything.

**Why it matters:** During a rebuild it's easy to attach the wrong disk. Initializing
or backing up onto the wrong volume can mix up or overwrite data.

**Steps (host):**

```bash
cp /data/.restic-volume-id /root/sentinel.pretest
echo bogus-volume-id > /data/.restic-volume-id
```

Then run the check on the control node. Optionally run the real apply with
`--tags restic` to see the hard stop.

**Expected (check):** `WARNING: a real run WOULD FAIL — a different data volume is
mounted than pinned`.

**Expected (apply):** fails at "Fail when a different data volume is mounted than
expected", before any init or restore.

**Rollback:**

```bash
cp /root/sentinel.pretest /data/.restic-volume-id
```

Run the check again: no sentinel warning.

### Test 4 — Repository identity pin mismatch

**What it tests:** The role notices when it's pointed at a different (or
re-initialized) repository than before.

**Why it matters:** A repo silently replaced with an empty one looks "healthy" to
restic. The pin is the only thing that notices the repository changed.

**Steps (control node):**

```bash
cp restic-state/prometheus.primary.repo-id /tmp/primary.repo-id.pretest
echo 0000000000000000 > restic-state/prometheus.primary.repo-id
```

Run the check, then run it again with `-e restic_repo_id_pin_strict=true`.

**Expected:** `WARNING: restic repository identity differs from the pinned value —
primary MISMATCH`. With strict on, the warning adds
`A real run with restic_repo_id_pin_strict would FAIL here.`

**Rollback:** `git checkout -- restic-state/prometheus.primary.repo-id`, then run the
check again: no warning.

### Test 5 — Control-node key lost, host intact

**What it tests:** If the control node is rebuilt and loses its key copy, the next run
recovers it from the live host — and never generates a new one.

**Why it matters:** The control-node copy is what lets you rebuild the host later. If
it's quietly missing, you'd find out at the worst possible time.

**Steps (control node):**

```bash
mv restic-state/prometheus.password ~/prometheus.password.pretest
```

Run the check, then the real apply with `--tags restic`.

**Expected (check):** no fail-early warning (the host still has the key); "Fetch
restic password file to control node" would run; generate/seed are skipped.

**Expected (apply):** `restic-state/prometheus.password` is recreated.

**Verify:**

```bash
sha256sum restic-state/prometheus.password ~/prometheus.password.pretest
```

The hashes must be identical. Keep the `.pretest` copy until Test 6 is done.

### Test 6 — No key anywhere, repositories exist (fail-early)

**What it tests:** When both the control node and the host have lost the key but
repositories still exist, the role stops early. It does not generate a new key or
initialize anything.

**Why it matters:** This is the worst case: a new key would permanently orphan every
existing backup. The role must stop and tell you to recover the key.

**Steps:**

On the control node:

```bash
mv restic-state/prometheus.password ~/prometheus.password.pretest2
```

On the host:

```bash
mv /etc/restic/password /root/password.pretest
```

Run the check. **Only if it shows the warning below**, run the real apply with
`--tags restic`.

**Expected (check):** `WARNING: a real run WOULD FAIL here — an initialized restic
repository exists … but no password is available`. If this warning is missing,
**stop** — do not apply.

**Expected (apply):** fails at "Fail early when a repository exists but no password is
available".

**Verify:** `/etc/restic/password` was not recreated; no control-node password file
was created; `restic cat config` ids (after rollback) still match the pins.

**Rollback:**

On the host:

```bash
mv /root/password.pretest /etc/restic/password
```

On the control node:

```bash
mv ~/prometheus.password.pretest2 restic-state/prometheus.password
```

Run the check: clean. Confirm both `sha256sum` values match 0.4.

---

## Phase 2 — Rebuild tests (destructive)

Required first: Phase 0 complete (especially 0.3), Tests 1–6 (including 2b) passed, and
daytime.

### Test 7 — `/data` lost, root disk intact → restore from the NAS

**What it tests:** The headline scenario. With the local repository and live data gone
but the root disk intact, the role detects the rebuilt volume, re-creates the local
repository, restores the data bundles from the NAS (the newest source), verifies them,
and re-blesses the host.

**Why it matters:** This is exactly the case that used to start fresh silently and
then erode the NAS through retention. It exercises multi-source selection, the
sentinel's "pinned but absent" signal, post-restore verification, and re-blessing
together.

This test simulates a fresh `/data` in place, by moving everything aside on the same
filesystem. It's instant and fully reversible. (A true volume replacement requires
replacing the instance too; that's Test 9.)

**Precondition:** free space on `/data` is at least the size of `/data/prometheus` from
0.2 — the restore writes a full copy.

**Steps (host):**

```bash
systemctl stop prometheus
systemctl stop 'restic-*.timer'
ls -la /data
mkdir /data/.pretest
mv /data/backups /data/letsencrypt /data/prometheus /data/.restic-volume-id /data/.pretest/
ls -la /data
```

If the first `ls` shows any other entries, move those into `/data/.pretest/` too. The
final `ls` should show only `.pretest`.

**Expected (check)** — run on the control node:

- restic: `NOTE: volume sentinel pinned but absent on host — … looks freshly rebuilt or
  unmounted`; no fail-early. "Unbless host before re-initializing the primary during
  recovery" would change. Repository init itself is skipped in check mode.
- restic_restore: source plan `present: primary, secondary; reachable: secondary`
  (the primary has no repository yet). "Unbless host before restoring" would change.
- `letsencrypt` and `prometheus`: `chosen_source: secondary`, action `RESTORE`.
- `prometheus_basic_auth`: `SKIP (target already populated)` — the root disk is intact.
- No "would fail" warning.

**Expected (apply)** — real apply with restic tags:

- The primary is re-initialized (empty, same key).
- The sentinel is written back using the pinned id.
- `letsencrypt` and `prometheus` are restored from `secondary`; the post-restore
  population check passes.
- The host is blessed.
- No repo-id warning on this run. The primary was unreadable when its id was read, so
  the mismatch only appears on the **next** check run (issue #2).

**If the apply fails**, check immediately on the host that it was left unblessed:

```bash
ls -la /etc/restic/blessed
systemctl stop 'restic-*.timer'
```

`ls` should report no such file — the marker is removed before any re-init or restore
is attempted, so the scheduled jobs will refuse to run. If the marker does exist after a failed recovery, that's a bug:
move it aside (`mv /etc/restic/blessed /root/blessed.failed`) so no backup or copy can
run, and investigate before continuing.

**Verify (host):**

```bash
diff -r /data/.pretest/letsencrypt /data/letsencrypt
diff <(ls /data/.pretest/prometheus) <(ls /data/prometheus)
cat /var/lib/restic_restore/prometheus.json
```

- `letsencrypt` should be identical.
- TSDB block directories should match. The WAL and any samples written after 0.1 are
  expected to be missing — that's your recovery point.
- The diagnostic marker should show `"snapshot_source": "secondary"`.

Then run the full play (check first, then apply). Prometheus should start, serve its
UI and API, and show history up to the 0.1 snapshot.

**Rollback** (recommended; this keeps the original primary history, chunker params,
and pin — issue #2):

```bash
systemctl stop prometheus
systemctl stop 'restic-*.timer'
mkdir /data/.posttest
mv /data/backups /data/letsencrypt /data/prometheus /data/.restic-volume-id /data/.posttest/
mv /data/.pretest/backups /data/.pretest/letsencrypt /data/.pretest/prometheus /data/.pretest/.restic-volume-id /data/
```

Then run the full play (check, then apply) and confirm the check is back to baseline
(0.5). Delete `/data/.posttest` and `/data/.pretest` once you're satisfied.

If you'd rather **keep** the restored state, the fresh primary needs re-pinning: delete
`restic-state/prometheus.primary.repo-id`, apply, and commit the new pin. It will still
dedup poorly against the NAS until issue #2 is addressed.

### Test 8 — Full instance rebuild (root disk fresh; `/data` and NAS intact)

**What it tests:** On a brand-new root filesystem, the role **reseeds the key from the
control node** instead of generating one, reads the intact local repository, and
restores the root-disk-resident bundle (`prometheus_basic_auth`) before the prometheus
role runs.

**Why it matters:** This is the chicken-and-egg fix. The key is backed up inside `/etc`
but can't be restored without the key. It also proves the basic-auth password survives
a rebuild instead of being regenerated, which would break every scraper using it.

**Steps (control node, `prometheus/tofu`):**

```bash
tofu plan -replace='incus_instance.system["prometheus"]'
```

Check that **only** the instance is replaced — both storage volumes untouched, no
`null_resource` replaced (issue #3). If anything else changes, **stop**. Then:

```bash
tofu apply -replace='incus_instance.system["prometheus"]'
ssh-keygen -R 10.10.30.11
ssh-keygen -R prometheus.hc.deney.io
```

Then, from `prometheus/ansible`: check, then real apply with restic tags.

**Expected (check):** limited, because restic isn't installed yet on the fresh root.
`restic_restore` warns that its gate would fail (binary/env missing) and the restore
plan shows as unresolved. That's expected. Signals: the password would be **seeded**
(not generated); primary repo present; sentinel matches.

**Expected (apply):**

- `/etc/restic/password` is seeded from the control node (no "Generate" task runs).
- No repository init.
- No repo-id or sentinel warnings.
- `prometheus_basic_auth` is restored with `chosen_source: primary` (snapshot times tie,
  so the primary wins).
- `letsencrypt` and `prometheus` are skipped (populated).
- The host is blessed.

Then run the full play (check, then apply). Tofu won't run it for you (issue #3).

**Verify:**

- `sha256sum /etc/restic/password` on the host equals the control-node file.
- Basic-auth `sha256sum` values match 0.2 (the password was reused, not regenerated).
- The certificate fingerprint matches 0.2.
- `certbot renew --dry-run` succeeds. ACME-DNS client state isn't a restore bundle, so
  this confirms it survived wherever it lives.
- Prometheus serves with its history, and scrapes using basic auth still work.
- `systemctl start restic-backup.service`, then `restic-copy.service`, both succeed,
  and a new snapshot appears in both repos.
- **Ownership watch:** `id prometheus` should match 0.2, and `ls -ln /data/prometheus | head`
  should show that uid. A fresh root may allocate a different uid; if it does, the
  persisted TSDB isn't writable — check the prometheus logs for permission errors.

### Test 9 — Instance and `/data` both rebuilt (only the NAS survives)

**What it tests:** The real disaster: a fresh root disk *and* a fresh `/data`. The key
is seeded from the control node, a new local repository is created, and every bundle is
restored from the NAS.

**Why it matters:** This is the scenario the whole design exists for. It also
permanently destroys the real local repository and live data, so the NAS (and your 0.3
copy) is all you have. Run it last, only after Tests 7 and 8 pass.

**Steps (control node, `prometheus/tofu`):**

```bash
tofu plan -replace='incus_instance.system["prometheus"]' -replace='incus_storage_volume.data["prometheus"]'
```

Check that the **backups volume is untouched**. If it appears in the plan, **stop**.
Then apply with the same arguments, clear SSH host keys as in Test 8, then check and
apply the restic tags.

**Expected (apply):**

- Key seeded from the control node.
- Fresh primary initialized.
- Sentinel "pinned but absent" note.
- All three bundles restored from `secondary`.
- Post-restore checks pass; host blessed.
- On the next check run: primary repo-id MISMATCH (issue #2).

**Verify:** everything in Test 8's verify list, plus the restore-fidelity checks
against 0.2: certificate fingerprint, basic-auth hashes, and TSDB blocks up to the 0.1
snapshot. The ownership watch item matters most here, because the TSDB is restored
before the prometheus role creates its user.

Afterwards, re-pin the primary (delete the control-node pin, apply, commit). Decide
whether to re-initialize the primary with NAS chunker params before backups accumulate
(issue #2).

### Test 10 (optional) — NAS unavailable during recovery

**What it tests:** An unmounted NAS is never mistaken for "no backups exist."

**Why it matters:** If the NAS silently disappears during a rebuild, the only correct
outcome is a loud failure, not a fresh start.

**Steps:** temporarily detach the device with your Incus remote:
`incus config device remove <remote>:prometheus backups`. Run the check, then the
apply. Reattach with `tofu apply` (the detach is tofu drift).

**Expected:** fails at "Fail when secondary repository mount is missing"; nothing is
initialized on the NAS path.

Combined with Test 7's simulation, no source has snapshots, so `restic_restore` also
fails and leaves the host unblessed.

### Not covered here

The genuine first-deploy path (no key and no repositories anywhere). It's best
exercised on a scratch instance, not prometheus.

---

## Cleanup

1. Remove the test copies: `/data/.pretest`, `/data/.posttest`, `/root/*.pretest`,
   `/root/blessed.failed`, `~/prometheus.password.pretest*`,
   `/tmp/primary.repo-id.pretest`.
2. On the host, clear failed units and confirm the schedule:

   ```bash
   systemctl reset-failed 'restic-*'
   systemctl list-timers 'restic-*'
   ```

3. Confirm `/etc/restic/blessed` exists and a final check run matches the 0.5
   baseline.
4. Commit any pin changes in `restic-state/`.
5. Remove the 0.3 NAS snapshot or copy once you no longer need it.

---

## Results log

| Test | Date | Check result | Apply result | Verified | Notes |
|---|---|---|---|---|---|
| 0.x Pre-flight | | | n/a | | |
| 1 Lockout | | n/a | n/a | | |
| 2 Re-bless | | | | | |
| 2b Selection dry run | | | n/a | | |
| 3 Sentinel mismatch | | | | | |
| 4 Repo-id mismatch | | | n/a | | |
| 5 Control key lost | | | | | |
| 6 No key anywhere | | | | | |
| 7 `/data` lost | | | | | |
| 8 Instance rebuilt | | | | | |
| 9 Instance + `/data` | | | | | |
| 10 NAS unavailable | | | | | |
