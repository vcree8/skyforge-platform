#!/usr/bin/env bash
# Unit 4 - Cloud Computing and DevOps  -  OTHM K/650/7997
# Artefact P4.13   Assessment criteria: AC 4.4
# Shell scripting for automation - fleet health check and self-remediation
# 
# Vera Cree  |  Candidate 240301062  |  CIPS Centre DC2401845

#
# healthcheck.sh - fleet health check with bounded self-remediation.
# Usage: ./healthcheck.sh [-e ENV] [-t THRESHOLD] [-n] [-h]
#
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
readonly LOG_DIR="/var/log/skyforge"
# Declared then assigned separately: combining them would mask the exit
# status of the command substitution (shellcheck SC2155).
LOG_FILE="${LOG_DIR}/healthcheck-$(date +%F).log"
readonly LOG_FILE

# Defaults, overridable by flags
ENVIRONMENT="production"
DISK_THRESHOLD=85
DRY_RUN=false

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]
  -e ENV        Environment to check (default: production)
  -t THRESHOLD  Disk usage percentage that triggers action (default: 85)
  -n            Dry run - report only, take no remediating action
  -h            Show this help
EOF
    exit "${1:-0}"
}

log() { printf '%s [%-5s] %s\n' "$(date -Is)" "$1" "$2" | tee -a "$LOG_FILE"; }
die() { log FATAL "$1"; exit "${2:-1}"; }
trap 'die "Unexpected failure at line $LINENO" 2' ERR
trap 'log INFO "Interrupted"; exit 130' INT TERM

# ---------- argument parsing ----------
while getopts ':e:t:nh' opt; do
    case "$opt" in
        e) ENVIRONMENT="$OPTARG" ;;
        t) DISK_THRESHOLD="$OPTARG" ;;
        n) DRY_RUN=true ;;
        h) usage 0 ;;
        :) die "Option -$OPTARG requires an argument" ;;
        ?) die "Unknown option -$OPTARG" ;;
    esac
done

[[ "$DISK_THRESHOLD" =~ ^[0-9]+$ ]] || die "Threshold must be numeric"
mkdir -p "$LOG_DIR"

# ---------- checks ----------
declare -a FAILURES=()
declare -i CHECKS=0

# record() must never return non-zero. Under `set -Eeuo pipefail` with an ERR
# trap, a non-zero return here aborts the whole run - and both statements in
# the original version returned 1 during entirely normal operation:
#
#   ((CHECKS++))   post-increment yields the OLD value, so while CHECKS is 0
#                  the arithmetic evaluates to 0 and the command exits 1.
#   [[ -n "$1" ]] && FAILURES+=("$1")
#                  with an empty argument the test is false, && short-circuits,
#                  and the function returns 1. record "" is the NORMAL path:
#                  it is how a check that PASSED gets counted.
#
# The effect was that the script died on its first healthy check. Pre-increment
# and a full if remove both, and the explicit return makes the contract plain,
# so the `A && record X || record ""` callers behave as if-then-else.
record() {
    (( ++CHECKS ))
    if [[ -n "$1" ]]; then FAILURES+=("$1"); fi
    return 0
}

check_disk() {
    log INFO "Checking filesystems (threshold ${DISK_THRESHOLD}%)"
    local line mount usage
    while read -r line; do
        usage=${line%% *}; mount=${line#* }
        if (( usage >= DISK_THRESHOLD )); then
            log WARN "${mount} at ${usage}%"
            if [[ "$DRY_RUN" == false ]]; then
                log INFO "Remediating ${mount}: journal vacuum + docker prune"
                journalctl --vacuum-size=200M >/dev/null 2>&1 || true
                docker system prune -af --filter 'until=168h' >/dev/null 2>&1 || true
                usage=$(df --output=pcent "$mount" | tail -1 | tr -dc '0-9')
                log INFO "${mount} now at ${usage}%"
            fi
            (( usage >= DISK_THRESHOLD )) && record "disk:${mount}:${usage}%" || record ""
        else
            record ""
        fi
    done < <(df --output=pcent,target -x tmpfs -x devtmpfs \
             | tail -n +2 | tr -d '%' | awk '{print $1" "$2}')
}

check_services() {
    local -a services=(docker kubelet chronyd sshd)
    log INFO "Checking services: ${services[*]}"
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc"; then
            record ""
        else
            log WARN "${svc} is not active"
            if [[ "$DRY_RUN" == false ]]; then
                log INFO "Attempting restart of ${svc}"
                systemctl restart "$svc" && sleep 3
            fi
            systemctl is-active --quiet "$svc" \
                && { log INFO "${svc} recovered"; record ""; } \
                || record "service:${svc}"
        fi
    done
}

check_endpoint() {
    local url="https://${ENVIRONMENT}.skyforge.io/health" code
    log INFO "Probing ${url}"
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" || echo 000)
    if [[ "$code" == "200" ]]; then record ""; else
        log WARN "Endpoint returned ${code}"; record "endpoint:${code}"
    fi
}

check_certificate() {
    local host="${ENVIRONMENT}.skyforge.io" expiry days
    expiry=$(echo | openssl s_client -connect "${host}:443" -servername "$host" 2>/dev/null \
             | openssl x509 -noout -enddate | cut -d= -f2)
    days=$(( ( $(date -d "$expiry" +%s) - $(date +%s) ) / 86400 ))
    log INFO "TLS certificate expires in ${days} days"
    (( days < 21 )) && { log WARN "Certificate expiring soon"; record "cert:${days}d"; } \
                    || record ""
}

# ---------- run ----------
log INFO "=== ${SCRIPT_NAME} starting (env=${ENVIRONMENT}, dry-run=${DRY_RUN}) ==="
check_disk
check_services
check_endpoint
check_certificate

# ---------- report ----------
log INFO "${CHECKS} checks run, ${#FAILURES[@]} unresolved"
if (( ${#FAILURES[@]} > 0 )); then
    printf -v body '%s\n' "${FAILURES[@]}"
    log ERROR "Unresolved: ${FAILURES[*]}"
    [[ "$DRY_RUN" == false ]] && aws sns publish --topic-arn "${SNS_TOPIC:-}" \
        --subject "[${ENVIRONMENT}] healthcheck: ${#FAILURES[@]} unresolved" \
        --message "$body" >/dev/null 2>&1 || true
    exit 1
fi
log INFO "All checks passed"
exit 0

# Scheduled: */15 * * * * /opt/skyforge/healthcheck.sh -e production
