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

```
root@prometheus:~#
set -a
. /etc/restic/env
set +a
root@prometheus:~# restic snapshots --latest 1
repository 9e4272ae opened (version 2, compression level auto)
ID        Time                 Host                    Tags        Paths                                          Size
-----------------------------------------------------------------------------------------------------------------------------
736e5860  2026-05-24 20:46:16  prometheus.hc.deney.io  scheduled   /etc                                           1.667 MiB

74172c6b  2026-06-28 02:24:01  prometheus.hc.deney.io  scheduled   /data/letsencrypt                              1.752 MiB
                                                                   /etc

7774759b  2026-11-12 04:12:02  prometheus.hc.deney.io  scheduled   /data/letsencrypt                              117.812 MiB
                                                                   /data/prometheus
                                                                   /etc
                                                                   /root/prometheus_basic_auth_password.txt
                                                                   /root/prometheus_basic_auth_password_hash.txt
-----------------------------------------------------------------------------------------------------------------------------
Timestamps shown in local time
3 snapshots
root@prometheus:~# restic cat config
repository 9e4272ae opened (version 2, compression level auto)
{
  "version": 2,
  "id": "9e4272aefe5555c88c6032de99d14c4850e85155998629f3e998026f01ba1d76",
  "chunker_polynomial": "38e7653ed3b299"
}



root@prometheus:~#
set -a
. /etc/restic/env.secondary
set +a
root@prometheus:~# restic cat config
repository 305e3164 opened (version 2, compression level auto)
{
  "version": 2,
  "id": "305e3164ed5a8ceb7dd75c69f08592b111d42576e9cff11c86aa9ac245ec0bc1",
  "chunker_polynomial": "38e7653ed3b299"
}
root@prometheus:~# restic snapshots --latest 1
repository 305e3164 opened (version 2, compression level auto)
ID        Time                 Host                    Tags        Paths                                          Size
-----------------------------------------------------------------------------------------------------------------------------
a3dd859b  2026-05-24 20:46:16  prometheus.hc.deney.io  scheduled   /etc                                           1.667 MiB

b1c02385  2026-06-28 02:24:01  prometheus.hc.deney.io  scheduled   /data/letsencrypt                              1.752 MiB
                                                                   /etc

8f391128  2026-11-12 04:12:02  prometheus.hc.deney.io  scheduled   /data/letsencrypt                              117.812 MiB
                                                                   /data/prometheus
                                                                   /etc
                                                                   /root/prometheus_basic_auth_password.txt
                                                                   /root/prometheus_basic_auth_password_hash.txt
-----------------------------------------------------------------------------------------------------------------------------
Timestamps shown in local time
3 snapshots



root@prometheus:~# cat /data/.restic-volume-id
a4467a9a-100c-431d-8165-40e54e53620c
root@prometheus:~# sha256sum /root/prometheus_basic_auth_password.txt /root/prometheus_basic_auth_password_hash.txt
fe7a0791adf70f55e6bbfdea54863fe27f963f41ec0de8a5a2f210b27dbd6093  /root/prometheus_basic_auth_password.txt
dfa051f59085e31d114f2a514286b352572d9c4872e5d3ba7fd06dfca1ea6afb  /root/prometheus_basic_auth_password_hash.txt
root@prometheus:~# openssl x509 -noout -fingerprint -sha256 -in /data/letsencrypt/live/prometheus.hc.deney.io/cert.pem
sha256 Fingerprint=EF:7C:A6:05:05:3F:A0:BB:55:2B:20:4E:3D:6E:4E:5B:95:5D:CA:56:4E:50:77:A9:A8:3B:B9:73:8D:FD:7E:A9
root@prometheus:~# ls /data/prometheus
01M4XNQ96YTF6RTAZAFK3BFX30  01M5MV9R7297K467GKGX94ZZTD  01M6C0W772TCK02DWH18GJF5GN  01M736EP8FWG79NYMXXR0ZP8TE  01M76DEJSA8H6T2ZQGB29WJWYD  chunks_head
01M53F3WZRKPBGG92TMQQXWNF1  01M5TMPC00ZWVGAFQDGG187H2V  01M6HT8TZ0SMJPWZTYCRJ8C7J9  01M75487ESMD7D27CW30M2W4WK  01M76DEJTTA0ZQ2Y5ND5KP5Z0M  lock
01M598GGQBMD52TZQGATNG0SB5  01M60E2ZQ1QDATPR7SHGFAHGYB  01M6QKNES7QV764Z2DAJRSWQEA  01M75RVD3W5N38RKFBFBFPP4D4  01M76MAA1DPCNT2P58SPJ8MS5Q  queries.active
01M5F1X4FXBHXKMDC9YASAKTSF  01M667FKG1BF4HT1GZ0J3Y8PZD  01M6XD22GKC745JZ6G4027Y85S  01M766JVHC3H3GN26AZ20PCG76  01M76V619AF1NS8NZR709Q4MEQ  wal
root@prometheus:~# du -sh /data/prometheus
44M     /data/prometheus
root@prometheus:~# df -h /data
Filesystem                            Size  Used Avail Use% Mounted on
local/custom/default_prometheus-data   50G  148M   50G   1% /data
root@prometheus:~# cat /etc/restic/blessed
{
    "fresh_start": false,
    "managed_by": "restic_restore role; restic jobs refuse to run without this file (see restic role RECOVERY.md)",
    "recovery_expected": true,
    "unsatisfied_critical": []
}
root@prometheus:~# id prometheus
uid=999(prometheus) gid=988(prometheus) groups=988(prometheus),989(cert-access)
```

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

```bash
source="mattjohnson@tauro:/srv/nas_lab_backup/tauro/custom/default_prometheus/"
destination="./prometheus-backup/"

mkdir -p "${destination}"
rsync -avz --rsync-path="sudo rsync" \
  "${source}" \
  "${destination}"
```

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

```bash
ansible-playbook playbooks/system.yml --diff --check --tags restic,restic_restore
```

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

```
Nov 12 04:24:17 prometheus.hc.deney.io systemd[1]: Starting restic-backup.service - Restic backup...
Nov 12 04:24:17 prometheus.hc.deney.io restic-backup.sh[30795]: ERROR: /etc/restic/blessed absent — host is not blessed for backups; refusing to run (unresolved rebuild/recovery?)
Nov 12 04:24:17 prometheus.hc.deney.io systemd[1]: restic-backup.service: Main process exited, code=exited, status=1/FAILURE
Nov 12 04:24:17 prometheus.hc.deney.io systemd[1]: restic-backup.service: Failed with result 'exit-code'.
Nov 12 04:24:17 prometheus.hc.deney.io systemd[1]: Failed to start restic-backup.service - Restic backup.
```

Repeat the last two lines for `restic-forget`, `restic-prune`, `restic-copy`,
`restic-forget-secondary`, and `restic-prune-secondary`. Then:

```bash
systemctl start restic-forget.service
journalctl -u restic-forget.service -n 20 --no-pager
systemctl start restic-prune.service
journalctl -u restic-prune.service -n 20 --no-pager
systemctl start restic-copy.service
journalctl -u restic-copy.service -n 20 --no-pager
systemctl start restic-forget-secondary.service
journalctl -u restic-forget-secondary.service -n 20 --no-pager
systemctl start restic-prune-secondary.service
journalctl -u restic-prune-secondary.service -n 20 --no-pager
```

```bash
systemctl start restic-check.service
```

```
Nov 12 04:27:44 prometheus.hc.deney.io systemd[1]: Starting restic-check.service - Restic check (metadata)...
Nov 12 04:27:44 prometheus.hc.deney.io restic-check.sh[30842]: using temporary cache in /tmp/restic-check-cache-1218950457
Nov 12 04:27:44 prometheus.hc.deney.io restic-check.sh[30842]: create exclusive lock for repository
Nov 12 04:27:45 prometheus.hc.deney.io restic-check.sh[30842]: load indexes
Nov 12 04:27:45 prometheus.hc.deney.io restic-check.sh[30842]: check all packs
Nov 12 04:27:45 prometheus.hc.deney.io restic-check.sh[30842]: check snapshots, trees and blobs
Nov 12 04:27:45 prometheus.hc.deney.io restic-check.sh[30842]: [0:00] 100.00%  25 / 25 snapshots
Nov 12 04:27:45 prometheus.hc.deney.io restic-check.sh[30842]: no errors were found
Nov 12 04:27:45 prometheus.hc.deney.io systemd[1]: restic-check.service: Deactivated successfully.
Nov 12 04:27:45 prometheus.hc.deney.io systemd[1]: Finished restic-check.service - Restic check (metadata).
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

```bash
ansible-playbook playbooks/system.yml --diff --tags restic,restic_restore --check
ansible-playbook playbooks/system.yml --diff --tags restic,restic_restore
```

**Expected (check):** "Bless host for backups (write blessed marker)" would change; no
failures or warnings.

**Expected (apply):** marker recreated; timers started again (changed — they were
stopped). `systemctl list-timers 'restic-*'` shows all ten timers scheduled.

```
root@prometheus:~# systemctl list-timers 'restic-*'
NEXT                                  LEFT LAST                              PASSED UNIT                              ACTIVATES
Fri 2026-11-13 02:12:55 UTC            21h Thu 2026-11-12 02:28:30 UTC 2h 20min ago restic-backup.timer               restic-backup.service
Fri 2026-11-13 03:18:59 UTC            22h Thu 2026-11-12 03:03:17 UTC 1h 45min ago restic-copy.timer                 restic-copy.service
Fri 2026-11-13 03:30:26 UTC            22h Thu 2026-11-12 03:57:26 UTC    51min ago restic-forget.timer               restic-forget.service
Fri 2026-11-13 03:57:26 UTC            23h Thu 2026-11-12 03:49:26 UTC    59min ago restic-forget-secondary.timer     restic-forget-secondary.service
Sat 2026-11-14 05:17:28 UTC         2 days Sat 2026-11-07 05:18:26 UTC   4 days ago restic-check.timer                restic-check.service
Sat 2026-11-14 05:57:43 UTC         2 days Sat 2026-11-07 05:44:20 UTC   4 days ago restic-check-secondary.timer      restic-check-secondary.service
Sun 2026-11-15 04:01:29 UTC         2 days Sun 2026-11-08 04:13:19 UTC   4 days ago restic-prune.timer                restic-prune.service
Sun 2026-11-15 04:34:07 UTC         2 days Sun 2026-11-08 04:52:20 UTC   3 days ago restic-prune-secondary.timer      restic-prune-secondary.service
Sun 2026-12-06 06:23:31 UTC 3 weeks 3 days Sun 2026-11-01 06:28:49 UTC            - restic-check-data.timer           restic-check-data.service
Sun 2026-12-06 06:42:53 UTC 3 weeks 3 days Sun 2026-11-01 06:40:49 UTC            - restic-check-data-secondary.timer restic-check-data-secondary.service

10 timers listed.
Pass --all to see loaded but inactive timers, too.
```

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

```
TASK [mttjohnson.infra.restic_restore : Plan summary] *******************************************************************************************************
ok: [prometheus] =>
    msg: |-
        bundle:            prometheus_basic_auth
        paths:             ['/root/prometheus_basic_auth_password.txt', '/root/prometheus_basic_auth_password_hash.txt']
        target:            /tmp/restore-dryrun
        selector_tags:     []
        selector_host:     (any)
        selector_paths:    ['/root/prometheus_basic_auth_password.txt', '/root/prometheus_basic_auth_password_hash.txt']
        restore_required:  True
        gate:              ok
        repo:              reachable
        sources_reachable: primary, secondary
        snapshot:          7774759b
          @ 2026-11-12T04:12:02.085120171Z
          (host=prometheus.hc.deney.io,
           tags=['scheduled'])
        chosen_source:     primary
        targets_populated: False
        action:            RESTORE

TASK [mttjohnson.infra.restic_restore : Unbless host before restoring (fail closed while a restore is in progress)] *****************************************
changed: [prometheus]

PLAY RECAP **************************************************************************************************************************************************
prometheus                 : ok=105  changed=6    unreachable=0    failed=0    skipped=80   rescued=0    ignored=0
```

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

```bash
ansible-playbook playbooks/system.yml --diff --tags restic --check
ansible-playbook playbooks/system.yml --diff --tags restic
```

**Expected (check):** `WARNING: a real run WOULD FAIL — a different data volume is
mounted than pinned`.

```
TASK [mttjohnson.infra.restic : Warn on volume sentinel anomaly (check mode / rebuilt-looking volume)] ******************************************************
ok: [prometheus] =>
    msg: 'WARNING: a real run WOULD FAIL — a different data volume is mounted than pinned
        (host=bogus-volume-id, pin=a4467a9a-100c-431d-8165-40e54e53620c).'
```

**Expected (apply):** fails at "Fail when a different data volume is mounted than
expected", before any init or restore.

```
TASK [mttjohnson.infra.restic : Fail when a different data volume is mounted than expected (real run)] ******************************************************
[ERROR]: Task failed: Action failed: The data volume mounted at /data does not match the
volume pinned for this host:
  on-host sentinel /data/.restic-volume-id: bogus-volume-id
  control-node pin /home/selvaran/projects/infra-experiment/prometheus/ansible/inventories/../restic-state/prometheus.volume.sentinel-id: a4467a9a-100c-431d-8165-40e54e53620c
Refusing to operate on the wrong disk. If this is an intentional replacement,
set restic_force_fresh_start=prometheus to adopt it.

Origin: /home/selvaran/projects/infra-experiment/prometheus/ansible/collections/ansible_collections/mttjohnson/infra/roles/restic/tasks/main.yml:292:3

290 # Unambiguous (both ids present and differ) — refuse rather than operate on the
291 # wrong disk. Override with restic_force_fresh_start to adopt the new volume.
292 - name: Fail when a different data volume is mounted than expected (real run)
      ^ column 3

fatal: [prometheus]: FAILED! =>
    changed: false
    msg: |-
        The data volume mounted at /data does not match the
        volume pinned for this host:
          on-host sentinel /data/.restic-volume-id: bogus-volume-id
          control-node pin /home/selvaran/projects/infra-experiment/prometheus/ansible/inventories/../restic-state/prometheus.volume.sentinel-id: a4467a9a-100c-431d-8165-40e54e53620c
        Refusing to operate on the wrong disk. If this is an intentional replacement,
        set restic_force_fresh_start=prometheus to adopt it.

PLAY RECAP **************************************************************************************************************************************************
prometheus                 : ok=23   changed=0    unreachable=0    failed=1    skipped=10   rescued=0    ignored=0
```

**Rollback:**

```bash
cp /root/sentinel.pretest /data/.restic-volume-id
```

Run the check again: no sentinel warning.

```
TASK [mttjohnson.infra.restic : Warn on volume sentinel anomaly (check mode / rebuilt-looking volume)] ******************************************************
skipping: [prometheus]
```

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

```bash
ansible-playbook playbooks/system.yml --diff --tags restic --check -e restic_repo_id_pin_strict=true
ansible-playbook playbooks/system.yml --diff --tags restic -e restic_repo_id_pin_strict=true
```

**Expected:** `WARNING: restic repository identity differs from the pinned value —
primary MISMATCH`. With strict on, the warning adds
`A real run with restic_repo_id_pin_strict would FAIL here.`

```
TASK [mttjohnson.infra.restic : Fail on repository identity mismatch (strict, real run)] ********************************************************************
skipping: [prometheus]

TASK [mttjohnson.infra.restic : Warn on repository identity mismatch] ***************************************************************************************
ok: [prometheus] =>
    msg: 'WARNING: restic repository identity differs from the pinned value — primary
        MISMATCH (pinned 0000000000000000 != live 9e4272aefe5555c88c6032de99d14c4850e85155998629f3e998026f01ba1d76);
        secondary ok. A real run with restic_repo_id_pin_strict would FAIL here.'
```

```
TASK [mttjohnson.infra.restic : Fail on repository identity mismatch (strict, real run)] ********************************************************************
[ERROR]: Task failed: Action failed: restic repository identity differs from the pinned value (pointed at a different
or re-initialized repository than before):
  primary: pinned 0000000000000000 != live 9e4272aefe5555c88c6032de99d14c4850e85155998629f3e998026f01ba1d76

Origin: /home/selvaran/projects/infra-experiment/prometheus/ansible/collections/ansible_collections/mttjohnson/infra/roles/restic/tasks/main.yml:778:3

776   when: restic_repo_id_pin_enabled | bool
777
778 - name: Fail on repository identity mismatch (strict, real run)
      ^ column 3

fatal: [prometheus]: FAILED! =>
    changed: false
    msg: |-
        restic repository identity differs from the pinned value (pointed at a different
        or re-initialized repository than before):
          primary: pinned 0000000000000000 != live 9e4272aefe5555c88c6032de99d14c4850e85155998629f3e998026f01ba1d76

PLAY RECAP **************************************************************************************************************************************************
prometheus                 : ok=42   changed=0    unreachable=0    failed=1    skipped=31   rescued=0    ignored=0
```

**Rollback:** `git checkout -- restic-state/prometheus.primary.repo-id`, then run the
check again: no warning.

```
TASK [mttjohnson.infra.restic : Warn on repository identity mismatch] ***************************************************************************************
skipping: [prometheus]
```

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

```bash
ansible-playbook playbooks/system.yml --diff --tags restic --check
ansible-playbook playbooks/system.yml --diff --tags restic
```

**Expected (check):** no fail-early warning (the host still has the key); "Fetch
restic password file to control node" would run; generate/seed are skipped.

```
TASK [mttjohnson.infra.restic : Fetch restic password file to control node] *********************************************************************************
skipping: [prometheus]

TASK [mttjohnson.infra.restic : Tighten permissions on fetched password file] *******************************************************************************
[ERROR]: Task failed: Module failed: file (/home/selvaran/projects/infra-experiment/prometheus/ansible/inventories/../restic-state/prometheus.password) is absent, cannot continue
Origin: /home/selvaran/projects/infra-experiment/prometheus/ansible/collections/ansible_collections/mttjohnson/infra/roles/restic/tasks/main.yml:445:7

443       ignore_errors: "{{ ansible_check_mode }}"
444
445     - name: Tighten permissions on fetched password file
          ^ column 7

fatal: [prometheus -> localhost]: FAILED! =>
    changed: false
    msg: file (/home/selvaran/projects/infra-experiment/prometheus/ansible/inventories/../restic-state/prometheus.password)
        is absent, cannot continue
    path: /home/selvaran/projects/infra-experiment/prometheus/ansible/inventories/../restic-state/prometheus.password
    state: absent
...ignoring
```

**Expected (apply):** `restic-state/prometheus.password` is recreated.

```
TASK [mttjohnson.infra.restic : Fetch restic password file to control node] *********************************************************************************
changed: [prometheus]

TASK [mttjohnson.infra.restic : Tighten permissions on fetched password file] *******************************************************************************
--- before
+++ after
@@ -1,3 +1,3 @@
-    mode: '0664'
+    mode: '0600'
     path: /home/selvaran/projects/infra-experiment/prometheus/ansible/inventories/../restic-state/prometheus.password


changed: [prometheus -> localhost]
```

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

```bash
ansible-playbook playbooks/system.yml --diff --tags restic --check
ansible-playbook playbooks/system.yml --diff --tags restic
```

**Expected (check):** `WARNING: a real run WOULD FAIL here — an initialized restic
repository exists … but no password is available`. If this warning is missing,
**stop** — do not apply.

```
TASK [mttjohnson.infra.restic : Fail early when a repository exists but no password is available (real run)] ************************************************
skipping: [prometheus]

TASK [mttjohnson.infra.restic : Warn when a repository exists but no password is available (check mode)] ****************************************************
ok: [prometheus] =>
    msg: 'WARNING: a real run WOULD FAIL here — an initialized restic repository exists
        (primary=True, secondary=True) but no password is available (host=False, control=False).
        Recover the control-node key and re-run.'
```

**Expected (apply):** fails at "Fail early when a repository exists but no password is
available".

```
TASK [mttjohnson.infra.restic : Fail early when a repository exists but no password is available (real run)] ************************************************
[ERROR]: Task failed: Action failed: An initialized restic repository exists but no password is available to read it:
  host key   /etc/restic/password: MISSING
  control key /home/selvaran/projects/infra-experiment/prometheus/ansible/inventories/../restic-state/prometheus.password: MISSING
  primary repo /data/backups: present
  secondary repo /backups: present
Refusing to generate a new password or initialize over the existing repository —
that would orphan the existing backups. Recover the control-node password copy
from your off-host secret store into /home/selvaran/projects/infra-experiment/prometheus/ansible/inventories/../restic-state/ and re-run.

Origin: /home/selvaran/projects/infra-experiment/prometheus/ansible/collections/ansible_collections/mttjohnson/infra/roles/restic/tasks/main.yml:326:3

324 # by restic_force_fresh_start — the operator must recover the key (or remove the
325 # repositories) deliberately.
326 - name: Fail early when a repository exists but no password is available (real run)
      ^ column 3

fatal: [prometheus]: FAILED! =>
    changed: false
    msg: |-
        An initialized restic repository exists but no password is available to read it:
          host key   /etc/restic/password: MISSING
          control key /home/selvaran/projects/infra-experiment/prometheus/ansible/inventories/../restic-state/prometheus.password: MISSING
          primary repo /data/backups: present
          secondary repo /backups: present
        Refusing to generate a new password or initialize over the existing repository —
        that would orphan the existing backups. Recover the control-node password copy
        from your off-host secret store into /home/selvaran/projects/infra-experiment/prometheus/ansible/inventories/../restic-state/ and re-run.

PLAY RECAP **************************************************************************************************************************************************
prometheus                 : ok=23   changed=0    unreachable=0    failed=1    skipped=12   rescued=0    ignored=0
```

**Verify:** `/etc/restic/password` was not recreated; no control-node password file
was created; `restic cat config` ids (after rollback) still match the pins.

```
root@prometheus:~# ls -la /etc/restic/password
ls: cannot access '/etc/restic/password': No such file or directory
```

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

```
(prometheus) selvaran@selvaran:~/projects/infra-experiment/prometheus/ansible$ sha256sum restic-state/prometheus.password
f2fe5388caf0ad371091b53084700f254c6dc3a9c14bd8ee74113f7b849a43ee  restic-state/prometheus.password
```
```
root@prometheus:~# sha256sum /etc/restic/password
f2fe5388caf0ad371091b53084700f254c6dc3a9c14bd8ee74113f7b849a43ee  /etc/restic/password
```

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

```bash
ansible-playbook playbooks/system.yml --diff --tags restic,restic_restore --check
ansible-playbook playbooks/system.yml --diff --tags restic,restic_restore
```

**Expected (check)** — run on the control node:

- restic: `NOTE: volume sentinel pinned but absent on host — … looks freshly rebuilt or
  unmounted`; no fail-early. "Unbless host before re-initializing the primary during
  recovery" would change. Repository init itself is skipped in check mode.

```
TASK [mttjohnson.infra.restic : Unbless host before re-initializing the primary during recovery] ************************************************************
--- before
+++ after
@@ -1,3 +1,3 @@
     path: /etc/restic/blessed
-    state: file
+    state: absent


changed: [prometheus]
```

- restic_restore: source plan `present: primary, secondary; reachable: secondary`
  (the primary has no repository yet). "Unbless host before restoring" would change.
```
TASK [mttjohnson.infra.restic_restore : Report restore source plan] *****************************************************************************************
ok: [prometheus] =>
    msg: 'restore sources — configured: primary, secondary; present: primary, secondary;
        reachable: secondary'
```
```
TASK [mttjohnson.infra.restic_restore : Track recovery-critical bundles that cannot be satisfied] ***********************************************************
ok: [prometheus]

TASK [mttjohnson.infra.restic_restore : Unbless host before restoring (fail closed while a restore is in progress)] *****************************************
--- before
+++ after
@@ -1,3 +1,3 @@
     path: /etc/restic/blessed
-    state: file
+    state: absent


changed: [prometheus]
```

- `letsencrypt` and `prometheus`: `chosen_source: secondary`, action `RESTORE`.
```
TASK [mttjohnson.infra.restic_restore : Plan summary] *******************************************************************************************************
ok: [prometheus] =>
    msg: |-
        bundle:            letsencrypt
        paths:             ['/data/letsencrypt']
        target:            (original)
        selector_tags:     []
        selector_host:     (any)
        selector_paths:    ['/data/letsencrypt']
        restore_required:  True
        gate:              ok
        repo:              reachable
        sources_reachable: secondary
        snapshot:          8f391128
          @ 2026-11-12T04:12:02.085120171Z
          (host=prometheus.hc.deney.io,
           tags=['scheduled'])
        chosen_source:     secondary
        targets_populated: False
        action:            RESTORE
```
```
TASK [mttjohnson.infra.restic_restore : Plan summary] *******************************************************************************************************
ok: [prometheus] =>
    msg: |-
        bundle:            prometheus
        paths:             ['/data/prometheus']
        target:            (original)
        selector_tags:     []
        selector_host:     (any)
        selector_paths:    ['/data/prometheus']
        restore_required:  True
        gate:              ok
        repo:              reachable
        sources_reachable: secondary
        snapshot:          8f391128
          @ 2026-11-12T04:12:02.085120171Z
          (host=prometheus.hc.deney.io,
           tags=['scheduled'])
        chosen_source:     secondary
        targets_populated: False
        action:            RESTORE
```

- `prometheus_basic_auth`: `SKIP (target already populated)` — the root disk is intact.
```
TASK [mttjohnson.infra.restic_restore : Plan summary] *******************************************************************************************************
ok: [prometheus] =>
    msg: |-
        bundle:            prometheus_basic_auth
        paths:             ['/root/prometheus_basic_auth_password.txt', '/root/prometheus_basic_auth_password_hash.txt']
        target:            (original)
        selector_tags:     []
        selector_host:     (any)
        selector_paths:    ['/root/prometheus_basic_auth_password.txt', '/root/prometheus_basic_auth_password_hash.txt']
        restore_required:  True
        gate:              ok
        repo:              reachable
        sources_reachable: secondary
        snapshot:          no matching snapshot
        chosen_source:     (none)
        targets_populated: True
        action:            SKIP (target already populated; idempotency guard)
```

- No "would fail" warning.

```
TASK [mttjohnson.infra.restic_restore : Write marker file] **************************************************************************************************
--- before: /var/lib/restic_restore/letsencrypt.json
+++ after: /var/lib/restic_restore/letsencrypt.json
@@ -3,7 +3,7 @@
     "paths": [
         "/data/letsencrypt"
     ],
-    "restored_at": "2026-05-25T17:55:04Z",
+    "restored_at": "2026-11-13T02:14:39Z",
     "selector": {
         "host": "",
         "paths": [
@@ -12,11 +12,12 @@
         "tags": []
     },
     "snapshot_hostname": "prometheus.hc.deney.io",
-    "snapshot_id": "0d05a18e4df7f42eaa83cab67c04314552da1e9bb73e575a7e856f0a2276acc6",
-    "snapshot_short_id": "0d05a18e",
+    "snapshot_id": "8f3911286dbb3c8fe58387ba183568b3f9c965816d646e77fa4a7683615dee95",
+    "snapshot_short_id": "8f391128",
+    "snapshot_source": "secondary",
     "snapshot_tags": [
         "scheduled"
     ],
-    "snapshot_time": "2026-05-24T20:52:08.028210992Z",
-    "target": "/data/test_restore"
+    "snapshot_time": "2026-11-12T04:12:02.085120171Z",
+    "target": ""
 }

changed: [prometheus]
```

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

```
root@prometheus:/data# cat /var/lib/restic_restore/prometheus.json
{
    "bundle": "prometheus",
    "paths": [
        "/data/prometheus"
    ],
    "restored_at": "2026-11-13T02:23:17Z",
    "selector": {
        "host": "",
        "paths": [
            "/data/prometheus"
        ],
        "tags": []
    },
    "snapshot_hostname": "prometheus.hc.deney.io",
    "snapshot_id": "8f3911286dbb3c8fe58387ba183568b3f9c965816d646e77fa4a7683615dee95",
    "snapshot_short_id": "8f391128",
    "snapshot_source": "secondary",
    "snapshot_tags": [
        "scheduled"
    ],
    "snapshot_time": "2026-11-12T04:12:02.085120171Z",
    "target": ""
}
```

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

```bash
ansible-playbook playbooks/system.yml --diff --tags restic,restic_restore --check
ansible-playbook playbooks/system.yml --diff --tags restic,restic_restore
```

**Expected (check):** limited, because restic isn't installed yet on the fresh root.
`restic_restore` warns that its gate would fail (binary/env missing) and the restore
plan shows as unresolved. That's expected. Signals: the password would be **seeded**
(not generated); primary repo present; sentinel matches.

```
TASK [mttjohnson.infra.restic_restore : Fail when restic is not installed (real run)] ***********************************************************************
skipping: [prometheus]

TASK [mttjohnson.infra.restic_restore : Warn when restic is not installed (check mode continues)] ***********************************************************
ok: [prometheus] =>
    msg: 'WARNING: restic_restore gate would fail in a real run. Missing: /usr/local/bin/restic,
        no restore source env file present (tried: /etc/restic/env, /etc/restic/env.secondary).
        Continuing check-mode inspection so the full per-bundle plan is visible.'
```

```
TASK [mttjohnson.infra.restic_restore : Plan summary] *******************************************************************************************************
ok: [prometheus] =>
    msg: |-
        bundle:            letsencrypt
        paths:             ['/data/letsencrypt']
        target:            (original)
        selector_tags:     []
        selector_host:     (any)
        selector_paths:    ['/data/letsencrypt']
        restore_required:  True
        gate:              FAILED (binary or env missing)
        repo:              UNREACHABLE
        sources_reachable: (none)
        snapshot:          unresolved (gate/repo failure — would query in a real run)
        chosen_source:     (none)
        targets_populated: True
        action:            SKIP (target already populated; idempotency guard)
```

**Expected (apply):**

- `/etc/restic/password` is seeded from the control node (no "Generate" task runs).
```
TASK [mttjohnson.infra.restic : Seed restic password from the control node (rebuild / recovery)] ************************************************************
changed: [prometheus]
```

- No repository init.
```
TASK [mttjohnson.infra.restic : Initialize restic repository] ***********************************************************************************************
skipping: [prometheus]
```
```
TASK [mttjohnson.infra.restic : Initialize secondary restic repository (chunker params from primary)] *******************************************************
skipping: [prometheus]
```

- No repo-id or sentinel warnings.
```
TASK [mttjohnson.infra.restic_restore : Report restore source plan] *****************************************************************************************
ok: [prometheus] =>
    msg: 'restore sources — configured: primary, secondary; present: primary, secondary;
        reachable: primary, secondary'
```

- `prometheus_basic_auth` is restored with `chosen_source: primary` (snapshot times tie,
  so the primary wins).
```
TASK [mttjohnson.infra.restic_restore : Plan summary] *******************************************************************************************************
ok: [prometheus] =>
    msg: |-
        bundle:            prometheus_basic_auth
        paths:             ['/root/prometheus_basic_auth_password.txt', '/root/prometheus_basic_auth_password_hash.txt']
        target:            (original)
        selector_tags:     []
        selector_host:     (any)
        selector_paths:    ['/root/prometheus_basic_auth_password.txt', '/root/prometheus_basic_auth_password_hash.txt']
        restore_required:  True
        gate:              ok
        repo:              reachable
        sources_reachable: primary, secondary
        snapshot:          7774759b
          @ 2026-11-12T04:12:02.085120171Z
          (host=prometheus.hc.deney.io,
           tags=['scheduled'])
        chosen_source:     primary
        targets_populated: False
        action:            RESTORE
```

- `letsencrypt` and `prometheus` are skipped (populated).
```
TASK [mttjohnson.infra.restic_restore : Plan summary] *******************************************************************************************************
ok: [prometheus] =>
    msg: |-
        bundle:            letsencrypt
        paths:             ['/data/letsencrypt']
        target:            (original)
        selector_tags:     []
        selector_host:     (any)
        selector_paths:    ['/data/letsencrypt']
        restore_required:  True
        gate:              ok
        repo:              reachable
        sources_reachable: primary, secondary
        snapshot:          no matching snapshot
        chosen_source:     (none)
        targets_populated: True
        action:            SKIP (target already populated; idempotency guard)
```
```
TASK [mttjohnson.infra.restic_restore : Plan summary] *******************************************************************************************************
ok: [prometheus] =>
    msg: |-
        bundle:            prometheus
        paths:             ['/data/prometheus']
        target:            (original)
        selector_tags:     []
        selector_host:     (any)
        selector_paths:    ['/data/prometheus']
        restore_required:  True
        gate:              ok
        repo:              reachable
        sources_reachable: primary, secondary
        snapshot:          no matching snapshot
        chosen_source:     (none)
        targets_populated: True
        action:            SKIP (target already populated; idempotency guard)
```

- The host is blessed.
```
TASK [mttjohnson.infra.restic_restore : Bless host for backups (write blessed marker)] **********************************************************************
--- before
+++ after: /etc/restic/blessed
@@ -0,0 +1,6 @@
+{
+    "fresh_start": false,
+    "managed_by": "restic_restore role; restic jobs refuse to run without this file (see restic role RECOVERY.md)",
+    "recovery_expected": true,
+    "unsatisfied_critical": []
+}

changed: [prometheus]
```

Then run the full play (check, then apply). Tofu won't run it for you (issue #3).

```bash
ansible-playbook playbooks/system.yml --diff --check
ansible-playbook playbooks/system.yml --diff
```

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
