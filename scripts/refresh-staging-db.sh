#!/usr/bin/env bash
# Unit 4 - Cloud Computing and DevOps  -  OTHM K/650/7997
# Artefact P4.4   Assessment criteria: AC 1.5
# Automation of a manual job - nightly database refresh of the staging environment
# 
# Vera Cree  |  Candidate 240301062  |  CIPS Centre DC2401845

# refresh-staging-db.sh - replaces a manual 40-minute weekly task.
# Scheduled nightly via EventBridge -> SSM Run Command.
set -Eeuo pipefail
IFS=$'\n\t'

# Declared then assigned separately: combining them would mask the exit
# status of the command substitution (shellcheck SC2155).
LOG="/var/log/skyforge/refresh-staging-$(date +%F).log"
readonly LOG
readonly SNAPSHOT_PREFIX="staging-refresh"
readonly PROD_DB="skyforge-prod-db"
readonly STAGING_DB="skyforge-staging-db"

# Supplied by the caller (EventBridge -> SSM Run Command sets it as an
# environment variable). Checked here rather than left to `set -u`, which would
# abort with a bare "SNS_TOPIC: unbound variable" at the moment of failure -
# inside fail(), so the alert about the failure would itself fail to send.
: "${SNS_TOPIC:?must be set to the SNS topic ARN that failure alerts are published to}"

log()  { printf '%s [%s] %s\n' "$(date -Is)" "$1" "$2" | tee -a "$LOG"; }
fail() { log ERROR "$1"; aws sns publish --topic-arn "$SNS_TOPIC" \
           --subject "Staging refresh FAILED" --message "$1" >/dev/null; exit 1; }
trap 'fail "Aborted at line $LINENO"' ERR

log INFO "=== Staging database refresh starting ==="

# 1. Snapshot production (point-in-time consistent, no downtime)
SNAP="${SNAPSHOT_PREFIX}-$(date +%Y%m%d-%H%M)"
log INFO "Creating snapshot ${SNAP}"
aws rds create-db-snapshot --db-instance-identifier "$PROD_DB" \
    --db-snapshot-identifier "$SNAP" >/dev/null
aws rds wait db-snapshot-available --db-snapshot-identifier "$SNAP"
log INFO "Snapshot available"

# 2. Drop the previous staging instance if present (idempotent)
if aws rds describe-db-instances --db-instance-identifier "$STAGING_DB" >/dev/null 2>&1; then
    log INFO "Deleting existing staging instance"
    aws rds delete-db-instance --db-instance-identifier "$STAGING_DB" \
        --skip-final-snapshot >/dev/null
    aws rds wait db-instance-deleted --db-instance-identifier "$STAGING_DB"
fi

# 3. Restore into the staging subnet group, smaller instance class
log INFO "Restoring ${SNAP} into ${STAGING_DB}"
aws rds restore-db-instance-from-db-snapshot \
    --db-instance-identifier "$STAGING_DB" \
    --db-snapshot-identifier "$SNAP" \
    --db-instance-class db.t4g.medium \
    --db-subnet-group-name skyforge-staging-subnets \
    --no-publicly-accessible >/dev/null
aws rds wait db-instance-available --db-instance-identifier "$STAGING_DB"

# 4. Anonymise personal data BEFORE any engineer can reach it (GDPR)
log INFO "Anonymising personal data"
ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier "$STAGING_DB" \
           --query 'DBInstances[0].Endpoint.Address' --output text)

# The restored instance inherits the master credentials from the snapshot, and
# those are held in Secrets Manager (terraform sets manage_master_user_password
# = true on the production instance). Fetch them at run time rather than
# carrying a database password in the environment or in this file.
SECRET_ARN=$(aws rds describe-db-instances --db-instance-identifier "$STAGING_DB" \
             --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
[ -n "$SECRET_ARN" ] && [ "$SECRET_ARN" != "None" ] \
    || fail "No managed master secret found on ${STAGING_DB}; cannot anonymise"

# The RDS-managed secret is {"username":...,"password":...}. Extracted with sed
# rather than jq to avoid adding a dependency to the SSM-managed host; RDS
# generates passwords from a character set that excludes the double quote, so
# the field cannot contain a delimiter that would break this.
PGPASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
             --query SecretString --output text \
             | sed -n 's/.*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[ -n "$PGPASSWORD" ] || fail "Could not read the master password from ${SECRET_ARN}"
export PGPASSWORD                       # both psql calls below need it

psql -h "$ENDPOINT" -U skyforge_admin \
     -d skyforge -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
UPDATE customers SET
    email      = 'user' || id || '@example.invalid',
    full_name  = 'Test User ' || id,
    phone      = '+44700900' || LPAD((id % 1000)::text, 3, '0'),
    date_of_birth = date_of_birth + (random() * 60 - 30)::int;
UPDATE payment_methods SET card_last_four = '0000', billing_postcode = 'SW1A 1AA';
DELETE FROM audit_log WHERE created_at < now() - interval '30 days';
COMMIT;
SQL
log INFO "Anonymisation complete"

# 5. Verify, then retain only the last 7 snapshots
psql -h "$ENDPOINT" -U skyforge_admin -d skyforge -tAc \
     "SELECT count(*) FROM customers WHERE email NOT LIKE '%@example.invalid'" \
     | grep -qx '0' || fail "Anonymisation verification FAILED - real emails remain"

# JMESPath uses backticks to delimit a literal, and the shell uses them for
# command substitution. Unescaped, the shell ran the prefix as a command and
# substituted its (empty) output, leaving a malformed query that silently
# matched nothing - so old snapshots were never pruned. Escaped, the backticks
# reach JMESPath intact.
RETAIN_QUERY="sort_by(DBSnapshots[?starts_with(DBSnapshotIdentifier,
                \`${SNAPSHOT_PREFIX}\`)],&SnapshotCreateTime)[:-7]"

aws rds describe-db-snapshots --snapshot-type manual \
    --query "${RETAIN_QUERY}.DBSnapshotIdentifier" \
    --output text | tr '\t' '\n' | while read -r old; do
        [ -n "$old" ] && aws rds delete-db-snapshot --db-snapshot-identifier "$old" >/dev/null
    done

log INFO "=== Refresh complete: 40 min manual task -> 0 min human effort ==="
