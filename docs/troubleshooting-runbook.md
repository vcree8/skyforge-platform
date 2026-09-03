# System troubleshooting runbook - worked incident

**Unit 4 - Cloud Computing and DevOps** &nbsp;·&nbsp; OTHM K/650/7997

| Field | Value |
|---|---|
| Artefact reference | P4.12 |
| Assessment criteria | AC 4.3 |
| Task | Task 2 (continued) |
| Learning outcome | LO4 - Linux system fundamentals, CLI, and user/group management |
| Learner | Vera Cree, candidate 240301062 |
| Centre | CIPS DC2401845 |

> A real diagnostic sequence rather than a command list: each step narrows the hypothesis space, and the resolution is tied back to a permanent fix. This is the structure the criterion on system troubleshooting is testing.

```text
  INCIDENT SKY-INC-441
  Symptom : p95 API latency rose from 180ms to 4.2s at 14:20; no deploy occurred
  Severity: P2      Detected by: SLO burn-rate alert (error budget 5x burn)

  STEP  HYPOTHESIS              COMMAND                          FINDING
  ----  ----------------------  -------------------------------  ----------------
  1     Host resource pressure  uptime; vmstat 1 5               load 0.9 - normal
                                free -h                          8.2/16 GB - normal
  2     Disk full or slow       df -h; df -i                     71% used - normal
                                iostat -xz 1 5                   %util 4% - normal
  3     CPU saturation          top -bn1 | head -20              12% - NOT the cause
                                mpstat -P ALL 1 3                no core saturated
  4     Network / connections   ss -s                            !! 28,431 sockets
                                ss -tan state time-wait | wc -l  !! 27,900 TIME_WAIT
  5     Which peer?             ss -tanp | awk '{print $5}' \      !! all to
                                  | cut -d: -f1 | sort | uniq -c    10.30.21.14:5432
                                  | sort -rn | head                 (the database)
  6     Connection pool         kubectl logs deploy/skyforge-api  "HikariPool-1 -
                                  -n production | grep -i pool     Connection is
                                                                   not available"
  7     Database side           psql -c "SELECT count(*),state    idle_in_transaction
                                  FROM pg_stat_activity           = 96 !!
                                  GROUP BY state;"
  8     Which query?            psql -c "SELECT pid, now()-       A report query
                                  xact_start AS age, query        holding a
                                  FROM pg_stat_activity WHERE     transaction open
                                  state='idle in transaction'     for 41 minutes
                                  ORDER BY age DESC LIMIT 5;"

  ROOT CAUSE
    A reporting endpoint opened a transaction, streamed results to the client,
    and did not commit until the stream closed. A slow client held the
    transaction open, exhausting the 100-connection Hikari pool. Application
    threads then blocked waiting for a connection, and the resulting socket
    churn produced the TIME_WAIT accumulation seen at step 4 - a SYMPTOM,
    not the cause. Chasing it would have wasted the incident.

  IMMEDIATE ACTION (14:52)
    psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
             WHERE state='idle in transaction'
               AND now() - xact_start > interval '5 minutes';"
    -> p95 returned to 190ms within 40 seconds.

  PERMANENT FIXES (raised as work items, all shipped within two sprints)
    1. idle_in_transaction_session_timeout = '5min' on the RDS parameter group
    2. Report endpoint changed to a read-only replica with a server-side cursor
    3. Hikari leakDetectionThreshold = 30000 to log offending call sites
    4. Alert added on pg_stat_activity idle-in-transaction count > 10
    5. Runbook entry added so step 7 is reached in minutes, not 30 minutes
```

---

## Evidence to capture

Attach the incident timeline from the observability tool and the before/after latency graph. Screenshot ref: SS-4.12a, SS-4.12b.
