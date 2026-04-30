# Cassandra Migration — Ansible + Shell Script

## File layout

```
cassandra_migration/
├── cassandra_migrate.sh          # ← main orchestration script (run this)
├── inventory.ini                 # ← your Ansible inventory
└── playbooks/
    ├── copy_data.yml             # Step 1 – parallel rsync of SSTables
    └── nodetool_import.yml       # Step 2 – nodetool import + Solr poll
```

---

## Quick start

```bash
# Make executable
chmod +x cassandra_migrate.sh

# Run in foreground (interactive)
./cassandra_migrate.sh -i inventory.ini -k keyspace1,keyspace2,keyspace3

# Run in BACKGROUND (detached from terminal)
nohup ./cassandra_migrate.sh \
    -i inventory.ini \
    -k keyspace1,keyspace2,keyspace3 \
    >> migration_master.log 2>&1 &

echo "Migration running as PID $!"

# Tail the live log
tail -f logs/migration_<timestamp>.log
```

---

## CLI flags

| Flag | Default | Description |
|------|---------|-------------|
| `-k` | (array in script) | Comma-separated keyspace list |
| `-i` | `inventory.ini`   | Ansible inventory file |
| `-l` | `./logs`          | Log output directory |
| `-p` | `120`             | Max Solr poll retries |
| `-w` | `30`              | Seconds between Solr checks |
| `-h` | —                 | Print help |

---

## How it works

```
For each keyspace (sequential):
│
├─ 1. COPY  ──► ansible-playbook copy_data.yml
│               (rsync runs in parallel across all source nodes via async)
│               Logs: logs/<keyspace>_copy_<ts>.log
│               ✔ prints START time, END time, copy duration
│
├─ 2. IMPORT ─► ansible-playbook nodetool_import.yml
│               (nodetool import fired on ALL target nodes simultaneously)
│               Logs: logs/<keyspace>_import_<ts>.log
│
└─ 3. POLL  ──► Re-run import playbook every 30 s (configurable)
                Parse stdout for Solr indexing output
                ┌─ non-empty stdout → still indexing, wait & retry
                └─ empty stdout     → indexing done, move to next keyspace
                Logs: logs/<keyspace>_solr_check_<attempt>.log
```

---

## Inventory example (`inventory.ini`)

```ini
[cassandra_source]
src-node1 ansible_host=10.0.0.1 target_node=10.0.1.1
src-node2 ansible_host=10.0.0.2 target_node=10.0.1.2
src-node3 ansible_host=10.0.0.3 target_node=10.0.1.3

[cassandra_target]
tgt-node1 ansible_host=10.0.1.1
tgt-node2 ansible_host=10.0.1.2
tgt-node3 ansible_host=10.0.1.3

[all:vars]
ansible_user=cassandra
ansible_ssh_private_key_file=~/.ssh/cassandra_key
```

---

## Sample output

```
[2026-04-29 09:00:00] [SECTION] ========== MIGRATION START ==========
[2026-04-29 09:00:00] [SECTION] ========== START  keyspace: keyspace1 ==========
[2026-04-29 09:00:00] [INFO]    Copy START time: 2026-04-29 09:00:00  [keyspace=keyspace1]
[2026-04-29 09:00:00] [INFO]    Running playbook: playbooks/copy_data.yml
[2026-04-29 09:47:12] [INFO]    Copy END   time: 2026-04-29 09:47:12  [keyspace=keyspace1]
[2026-04-29 09:47:12] [INFO]    Copy duration  : 00h 47m 12s  [keyspace=keyspace1]
[2026-04-29 09:47:12] [INFO]    Triggering nodetool import on all nodes
[2026-04-29 09:47:45] [INFO]    Waiting for Solr indexing to complete ...
[2026-04-29 09:48:15] [INFO]    Solr check attempt 1/120 — still active (3 node(s)), waiting 30s
[2026-04-29 10:02:05] [INFO]    Solr indexing complete for keyspace: keyspace1
[2026-04-29 10:02:05] [INFO]    Keyspace total duration: 01h 02m 05s
[2026-04-29 10:02:05] [SECTION] ========== END  keyspace: keyspace1  (01h 02m 05s) ==========

========== MIGRATION SUMMARY ==========
KEYSPACE                       STATUS       DURATION
------------------------------  ----------  --------------------
keyspace1                      SUCCESS     01h 02m 05s
keyspace2                      SUCCESS     00h 38m 44s
keyspace3                      FAILED(copy) 00h 05m 01s
```

---

## Adjusting the Solr detection pattern

In `cassandra_migrate.sh`, the Solr-idle check parses the Ansible playbook log:

```bash
active_indexing=$(grep -E "stdout.*[a-zA-Z]" "${check_log}" | grep -v "^$" | wc -l || true)
```

Tune this regex to match whatever `nodetool import` outputs on your cluster.
Common patterns to match:

- `"SOLR_STATUS.*: [^ ]"` — matches the debug msg in the sample playbook
- `"indexing"`, `"pending"`, `"compacting"` — match Solr-specific keywords

---

## Environment variables (alternative to flags)

```bash
export INVENTORY_FILE=inventory.ini
export COPY_PLAYBOOK=playbooks/copy_data.yml
export IMPORT_PLAYBOOK=playbooks/nodetool_import.yml
export LOG_DIR=/var/log/cassandra_migration
export SOLR_CHECK_MAX_RETRIES=240
export SOLR_CHECK_INTERVAL=60
export ANSIBLE_EXTRA_VARS="env=prod datacenter=dc1"

nohup ./cassandra_migrate.sh >> migration_master.log 2>&1 &
```
