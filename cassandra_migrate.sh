#!/usr/bin/env bash
# =============================================================================
# cassandra_migrate.sh
# Sequentially copies keyspaces from source Cassandra to target Cassandra
# using Ansible playbooks, waits for Solr indexing to complete after each.
#
# Usage:
#   ./cassandra_migrate.sh [OPTIONS]
#
# Options:
#   -f  Path to file containing keyspaces (one per line, # lines ignored)
#   -c  Full ansible copy command template   (use {keyspace} as placeholder)
#   -m  Full ansible import command template (use {keyspace} as placeholder)
#   -l  Log directory (default: ./logs)
#   -p  Max retries for Solr indexing check (default: 90 = 3 hours at 2 min intervals)
#   -w  Wait interval in seconds between Solr checks (default: 120)
#   -h  Show this help
#
# Run in background:
#   nohup ./cassandra_migrate.sh -f keyspaces.txt >> migration_master.log 2>&1 &
#   echo "PID: $!"
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Default Configuration — override via CLI flags or environment variables
# ---------------------------------------------------------------------------
# Path to newline-delimited keyspace list file (one keyspace per line; # = comment)
KEYSPACES_FILE="${KEYSPACES_FILE:-keyspaces.txt}"

# Populated at runtime from KEYSPACES_FILE — do not set manually here
KEYSPACES=()

# Full ansible-playbook commands — substitute {keyspace} at runtime.
# Edit these two lines to match your actual inventory, hosts, users and extra-vars.
COPY_CMD_TEMPLATE="${COPY_CMD_TEMPLATE:-ansible-playbook playbooks/dat_copy.yaml -i inventory/node.ini -e 'source=src-host target=tgt-host target_keyspace={keyspace}' -u cassandra}"
IMPORT_CMD_TEMPLATE="${IMPORT_CMD_TEMPLATE:-ansible-playbook playbooks/nodetool_import.yaml -i inventory/node.ini -e 'target_keyspace={keyspace}' -u cassandra}"

LOG_DIR="${LOG_DIR:-./logs}"
SOLR_CHECK_MAX_RETRIES="${SOLR_CHECK_MAX_RETRIES:-90}"    # 90 * 120s = 3 hours max wait
SOLR_CHECK_INTERVAL="${SOLR_CHECK_INTERVAL:-120}"         # seconds between checks (2 min)

# ---------------------------------------------------------------------------
# Colour codes
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
mkdir -p "${LOG_DIR}"
MASTER_LOG="${LOG_DIR}/migration_$(date +%Y%m%d_%H%M%S).log"

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local colour=""
    case "${level}" in
        INFO)    colour="${GREEN}"  ;;
        WARN)    colour="${YELLOW}" ;;
        ERROR)   colour="${RED}"    ;;
        SECTION) colour="${CYAN}${BOLD}" ;;
        *)       colour="${RESET}"  ;;
    esac
    local line="[${ts}] [${level}] ${msg}"
    echo -e "${colour}${line}${RESET}"
    echo "${line}" >> "${MASTER_LOG}"
}

log_section() { log SECTION "========== $* =========="; }

# ---------------------------------------------------------------------------
# Timing helpers
# ---------------------------------------------------------------------------
format_duration() {
    local seconds=$1
    local h=$(( seconds / 3600 ))
    local m=$(( (seconds % 3600) / 60 ))
    local s=$(( seconds % 60 ))
    printf "%02dh %02dm %02ds" "${h}" "${m}" "${s}"
}

# ---------------------------------------------------------------------------
# Summary table — printed at the end
# ---------------------------------------------------------------------------
declare -A KS_STATUS
declare -A KS_DURATION

print_summary() {
    log_section "MIGRATION SUMMARY"
    printf "\n%-30s %-12s %-20s\n" "KEYSPACE" "STATUS" "DURATION"
    printf "%-30s %-12s %-20s\n" "$(printf '%0.s-' {1..30})" "$(printf '%0.s-' {1..12})" "$(printf '%0.s-' {1..20})"
    for ks in "${KEYSPACES[@]}"; do
        local status="${KS_STATUS[$ks]:-SKIPPED}"
        local dur="${KS_DURATION[$ks]:-N/A}"
        printf "%-30s %-12s %-20s\n" "${ks}" "${status}" "${dur}"
    done
    printf "\n"
    echo "Full log: ${MASTER_LOG}"
}

# ---------------------------------------------------------------------------
# Run a command template with {keyspace} substituted.
# run_command <template> <keyspace> <tag>
# ---------------------------------------------------------------------------
run_command() {
    local template="$1"
    local keyspace="$2"
    local tag="$3"       # copy | import
    local ks_log="${LOG_DIR}/${keyspace}_${tag}_$(date +%Y%m%d_%H%M%S).log"

    # Substitute {keyspace} placeholder
    local cmd="${template//\{keyspace\}/${keyspace}}"

    log INFO "Running command [${tag}]: ${cmd}"
    log INFO "Command log: ${ks_log}"

    if eval "${cmd}" > "${ks_log}" 2>&1; then
        log INFO "Command succeeded [${tag}]  [keyspace=${keyspace}]"
        return 0
    else
        log ERROR "Command FAILED [${tag}]  [keyspace=${keyspace}] — see ${ks_log}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Wait until nodetool import output is empty (Solr indexing complete)
#
# The import playbook is expected to write its stdout to a temp file so we
# can inspect it.  We re-run the playbook each iteration and check whether
# the registered output variable is empty.  Adjust the grep pattern to match
# whatever your playbook actually emits.
# ---------------------------------------------------------------------------
wait_for_solr_idle() {
    local keyspace="$1"
    local attempt=0

    log INFO "Waiting for Solr indexing to complete for keyspace: ${keyspace}"

    while true; do
        attempt=$(( attempt + 1 ))

        if [[ ${attempt} -gt ${SOLR_CHECK_MAX_RETRIES} ]]; then
            log ERROR "Solr indexing check timed out after ${attempt} attempts for keyspace: ${keyspace}"
            return 1
        fi

        local check_log="${LOG_DIR}/${keyspace}_solr_check_${attempt}.log"

        log INFO "Solr check attempt ${attempt}/${SOLR_CHECK_MAX_RETRIES} for keyspace: ${keyspace}"

        # Run the import command with solr_check_only=true appended to extra-vars
        local cmd="${IMPORT_CMD_TEMPLATE//\{keyspace\}/${keyspace}}"
        # Append solr_check_only flag — works whether -e uses single or double quotes
        cmd="${cmd} -e 'solr_check_only=true'"

        eval "${cmd}" \
            > "${check_log}" 2>&1 || {
                log WARN "Import playbook returned non-zero on attempt ${attempt}; will retry."
            }

        # ---------------------------------------------------------------
        # Determine whether any node still shows Solr indexing output.
        # The playbook should write a sentinel file per node:
        #   /tmp/nodetool_import_<keyspace>_<node>.out
        # or use Ansible's fetch/register. We parse the Ansible JSON output
        # looking for non-empty stdout in the nodetool_import task.
        # Adjust the grep pattern below to match your playbook output.
        # ---------------------------------------------------------------
        local active_indexing
        active_indexing=$(grep -E "stdout.*[a-zA-Z]" "${check_log}" | grep -v "^$" | wc -l || true)

        if [[ "${active_indexing}" -eq 0 ]]; then
            log INFO "Solr indexing complete for keyspace: ${keyspace}"
            return 0
        fi

        log INFO "Solr indexing still active (${active_indexing} node(s)) — waiting ${SOLR_CHECK_INTERVAL}s ..."
        sleep "${SOLR_CHECK_INTERVAL}"
    done
}

# ---------------------------------------------------------------------------
# Process a single keyspace
# ---------------------------------------------------------------------------
migrate_keyspace() {
    local keyspace="$1"

    log_section "START  keyspace: ${keyspace}"
    local start_epoch
    start_epoch=$(date +%s)
    local start_ts
    start_ts=$(date '+%Y-%m-%d %H:%M:%S')
    log INFO "Copy START time: ${start_ts}  [keyspace=${keyspace}]"

    # ── Step 1: Data copy (parallel across nodes inside the playbook) ───────
    if ! run_command "${COPY_CMD_TEMPLATE}" "${keyspace}" "copy"; then
        log ERROR "Data copy failed for keyspace: ${keyspace}"
        KS_STATUS["${keyspace}"]="FAILED(copy)"
        local end_epoch; end_epoch=$(date +%s)
        KS_DURATION["${keyspace}"]=$(format_duration $(( end_epoch - start_epoch )))
        return 1
    fi

    local copy_end_ts
    copy_end_ts=$(date '+%Y-%m-%d %H:%M:%S')
    local copy_end_epoch
    copy_end_epoch=$(date +%s)
    local copy_duration
    copy_duration=$(format_duration $(( copy_end_epoch - start_epoch )))

    log INFO "Copy END   time: ${copy_end_ts}  [keyspace=${keyspace}]"
    log INFO "Copy duration  : ${copy_duration}  [keyspace=${keyspace}]"

    # ── Step 2: nodetool import on all nodes ────────────────────────────────
    log INFO "Triggering nodetool import on all nodes [keyspace=${keyspace}]"
    if ! run_command "${IMPORT_CMD_TEMPLATE}" "${keyspace}" "import"; then
        log ERROR "nodetool import trigger failed for keyspace: ${keyspace}"
        KS_STATUS["${keyspace}"]="FAILED(import)"
        local end_epoch; end_epoch=$(date +%s)
        KS_DURATION["${keyspace}"]=$(format_duration $(( end_epoch - start_epoch )))
        return 1
    fi

    # ── Step 3: Poll until Solr indexing finishes ───────────────────────────
    if ! wait_for_solr_idle "${keyspace}"; then
        log ERROR "Solr idle wait failed for keyspace: ${keyspace}"
        KS_STATUS["${keyspace}"]="FAILED(solr_timeout)"
        local end_epoch; end_epoch=$(date +%s)
        KS_DURATION["${keyspace}"]=$(format_duration $(( end_epoch - start_epoch )))
        return 1
    fi

    local end_epoch
    end_epoch=$(date +%s)
    local end_ts
    end_ts=$(date '+%Y-%m-%d %H:%M:%S')
    local total_duration
    total_duration=$(format_duration $(( end_epoch - start_epoch )))

    log INFO "Keyspace END   time    : ${end_ts}  [keyspace=${keyspace}]"
    log INFO "Keyspace total duration: ${total_duration}  [keyspace=${keyspace}]"
    log_section "END    keyspace: ${keyspace}  (${total_duration})"

    KS_STATUS["${keyspace}"]="SUCCESS"
    KS_DURATION["${keyspace}"]="${total_duration}"
    return 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

while getopts "f:c:m:l:p:w:h" opt; do
    case "${opt}" in
        f) KEYSPACES_FILE="${OPTARG}" ;;      # path to keyspaces file
        c) COPY_CMD_TEMPLATE="${OPTARG}" ;;   # override full copy ansible command
        m) IMPORT_CMD_TEMPLATE="${OPTARG}" ;; # override full import ansible command
        l) LOG_DIR="${OPTARG}" ;;
        p) SOLR_CHECK_MAX_RETRIES="${OPTARG}" ;;
        w) SOLR_CHECK_INTERVAL="${OPTARG}" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
log_section "PREFLIGHT CHECKS"

for bin in ansible-playbook date; do
    if ! command -v "${bin}" &>/dev/null; then
        log ERROR "Required binary not found: ${bin}"
        exit 1
    fi
done

# Load keyspaces from file
if [[ ! -f "${KEYSPACES_FILE}" ]]; then
    log ERROR "Keyspaces file not found: ${KEYSPACES_FILE}"
    exit 1
fi

# Read lines, strip whitespace, skip blank lines and comments (#)
while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line//[[:space:]]/}"          # strip all whitespace
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    KEYSPACES+=("${line}")
done < "${KEYSPACES_FILE}"

if [[ ${#KEYSPACES[@]} -eq 0 ]]; then
    log ERROR "No keyspaces found in file: ${KEYSPACES_FILE}"
    exit 1
fi

log INFO "Keyspaces file        : ${KEYSPACES_FILE}"
log INFO "Keyspaces loaded      : ${#KEYSPACES[@]}  →  ${KEYSPACES[*]}"
log INFO "Copy command template : ${COPY_CMD_TEMPLATE}"
log INFO "Import command template: ${IMPORT_CMD_TEMPLATE}"
log INFO "Log directory         : ${LOG_DIR}"
log INFO "Solr max wait         : ${SOLR_CHECK_MAX_RETRIES} retries x ${SOLR_CHECK_INTERVAL}s = $(( SOLR_CHECK_MAX_RETRIES * SOLR_CHECK_INTERVAL / 3600 ))h $(( (SOLR_CHECK_MAX_RETRIES * SOLR_CHECK_INTERVAL % 3600) / 60 ))m per keyspace"

# ---------------------------------------------------------------------------
# Main loop — sequential keyspace migration
# ---------------------------------------------------------------------------
log_section "MIGRATION START"
OVERALL_START=$(date +%s)
OVERALL_FAILED=0

for ks in "${KEYSPACES[@]}"; do
    if ! migrate_keyspace "${ks}"; then
        log ERROR "Migration FAILED for keyspace: ${ks}  — continuing with next keyspace."
        OVERALL_FAILED=$(( OVERALL_FAILED + 1 ))
    fi
done

OVERALL_END=$(date +%s)
OVERALL_DURATION=$(format_duration $(( OVERALL_END - OVERALL_START )))

log_section "MIGRATION COMPLETE"
log INFO "Total duration : ${OVERALL_DURATION}"
log INFO "Failed keyspaces: ${OVERALL_FAILED}"

print_summary | tee -a "${MASTER_LOG}"

if [[ ${OVERALL_FAILED} -gt 0 ]]; then
    log ERROR "${OVERALL_FAILED} keyspace(s) failed. Check logs in: ${LOG_DIR}"
    exit 1
fi

log INFO "All keyspaces migrated successfully."
exit 0
