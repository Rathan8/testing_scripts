# Cassandra Migration — Ansible + Shell Script

## File layout

```text
cassandra_migration/
├── cassandra_migrate.sh          # ← main orchestration script (run this)
├── keyspaces.txt                 # ← one keyspace per line, # = comment
└── playbooks/
    ├── dat_copy.yaml             # Step 1 – parallel data copy across nodes
    └── nodetool_import.yaml      # Step 2 – nodetool import + Solr poll
```

---

## keyspaces.txt format

One keyspace per line. Blank lines and lines starting with `#` are ignored.

```text
# Production keyspaces — migrated in order top to bottom
keyspace1
keyspace2
keyspace3
```

---

## Quick start

```bash
# Make executable
chmod +x cassandra_migrate.sh

# Run in foreground
./cassandra_migrate.sh -f keyspaces.txt

# Run in BACKGROUND (detached from terminal)
nohup ./cassandra_migrate.sh -f keyspaces.txt >> migration_master.log 2>&1 &
echo "Migration running as PID $!"

# Tail the live log
tail -f logs/migration_<timestamp>.log
```

---

## CLI flags

| Flag | Default | Description |
| ---- | ------- | ----------- |
| `-f` | `keyspaces.txt` | Path to keyspace list file |
| `-c` | (template in script) | Full ansible copy command — use `{keyspace}` as placeholder |
| `-m` | (template in script) | Full ansible import command — use `{keyspace}` as placeholder |
| `-l` | `./logs` | Log output directory |
| `-p` | `90` | Max Solr poll retries (90 × 120 s = **3 hours** max per keyspace) |
| `-w` | `120` | Seconds between Solr checks (2 min) |
| `-h` | — | Print help |

> The script **fails the keyspace** and moves on if Solr indexing has not
> completed within the retry limit (default 3 hours).

---

## Ansible command templates

Edit the two template variables at the top of `cassandra_migrate.sh` to match
your environment. Use `{keyspace}` as the runtime placeholder — it is
substituted for every keyspace automatically.

```bash
COPY_CMD_TEMPLATE="ansible-playbook playbooks/dat_copy.yaml \
  -i inventory/node.ini \
  -e 'source=src-host target=tgt-host target_keyspace={keyspace}' \
  -u cassandra"

IMPORT_CMD_TEMPLATE="ansible-playbook playbooks/nodetool_import.yaml \
  -i inventory/node.ini \
  -e 'target_keyspace={keyspace}' \
  -u cassandra"
```

Each playbook receives completely independent `extra-vars` — there is no
shared argument list between them.

---

## How it works

```text
For each keyspace (strictly sequential):
│
├─ 1. COPY  ──► run COPY_CMD_TEMPLATE  (parallelism is inside the playbook)
│               Logs: logs/<keyspace>_copy_<ts>.log
│               Prints: START time, END time, copy duration
│
├─ 2. IMPORT ─► run IMPORT_CMD_TEMPLATE
│               (triggers nodetool import on ALL target nodes simultaneously)
│               Logs: logs/<keyspace>_import_<ts>.log
│
└─ 3. POLL  ──► Re-run IMPORT_CMD_TEMPLATE with solr_check_only=true
                every 120 s, up to 90 times (3 hours max)
                ┌─ non-empty stdout → still indexing, wait & retry
                └─ empty stdout     → done, move to next keyspace
                ✘ timeout           → FAILED(solr_timeout), continue to next
                Logs: logs/<keyspace>_solr_check_<attempt>.log
```

---

## Sample output

```text
[2026-04-29 09:00:00] [SECTION] ========== PREFLIGHT CHECKS ==========
[2026-04-29 09:00:00] [INFO]    Keyspaces file        : keyspaces.txt
[2026-04-29 09:00:00] [INFO]    Keyspaces loaded      : 3  →  keyspace1 keyspace2 keyspace3
[2026-04-29 09:00:00] [INFO]    Solr max wait         : 90 retries x 120s = 3h 0m per keyspace
[2026-04-29 09:00:00] [SECTION] ========== MIGRATION START ==========
[2026-04-29 09:00:00] [SECTION] ========== START  keyspace: keyspace1 ==========
[2026-04-29 09:00:00] [INFO]    Copy START time: 2026-04-29 09:00:00
[2026-04-29 09:47:12] [INFO]    Copy END   time: 2026-04-29 09:47:12
[2026-04-29 09:47:12] [INFO]    Copy duration  : 00h 47m 12s
[2026-04-29 09:47:45] [INFO]    Waiting for Solr indexing to complete ...
[2026-04-29 09:49:45] [INFO]    Solr check attempt 1/90 — still active (3 node(s)), waiting 120s
[2026-04-29 10:02:05] [INFO]    Solr indexing complete for keyspace: keyspace1
[2026-04-29 10:02:05] [INFO]    Keyspace total duration: 01h 02m 05s
[2026-04-29 10:02:05] [SECTION] ========== END  keyspace: keyspace1  (01h 02m 05s) ==========

========== MIGRATION SUMMARY ==========
KEYSPACE                       STATUS       DURATION
------------------------------  ----------  --------------------
keyspace1                      SUCCESS      01h 02m 05s
keyspace2                      SUCCESS      00h 38m 44s
keyspace3                      FAILED(solr_timeout) 03h 00m 00s
```

---

## Adjusting the Solr detection pattern

In `cassandra_migrate.sh`, the Solr-idle check greps the playbook log:

```bash
active_indexing=$(grep -E "stdout.*[a-zA-Z]" "${check_log}" | grep -v "^$" | wc -l || true)
```

Tune this regex to match what `nodetool import` outputs on your cluster, e.g.:

- `"SOLR_STATUS.*: [^ ]"` — matches the `debug` msg in the sample playbook
- `"indexing|pending|compacting"` — match Solr-specific keywords directly

---

## Environment variables (alternative to CLI flags)

```bash
export KEYSPACES_FILE=/opt/migration/keyspaces.txt
export COPY_CMD_TEMPLATE="ansible-playbook playbooks/dat_copy.yaml -i inventory/node.ini -e 'source=h1 target=h2 target_keyspace={keyspace}' -u cassandra"
export IMPORT_CMD_TEMPLATE="ansible-playbook playbooks/nodetool_import.yaml -i inventory/node.ini -e 'target_keyspace={keyspace}' -u cassandra"
export LOG_DIR=/var/log/cassandra_migration
export SOLR_CHECK_MAX_RETRIES=90
export SOLR_CHECK_INTERVAL=120

nohup ./cassandra_migrate.sh >> migration_master.log 2>&1 &
```
