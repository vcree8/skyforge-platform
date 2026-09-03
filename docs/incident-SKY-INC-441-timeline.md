# Incident record — SKY-INC-441

**Skyforge Systems** · Platform Engineering

| | |
|---|---|
| Artefact reference | P4.12 (supporting) |
| Assessment criteria | AC 4.3 — system troubleshooting |
| Unit | Unit 4 — Cloud Computing and DevOps, OTHM K/650/7997 |
| Incident | API latency degradation, production |
| Severity | P2 — degraded service, no data loss |
| Detected | 14:23, by SLO burn-rate alert |
| Resolved | 14:52 |
| Duration | 29 minutes |
| Incident lead | Vera Cree |

---

## Impact

| Measure | Steady state | During incident |
|---|---|---|
| p95 API latency | 180 ms | 4,200 ms |
| p99 API latency | 340 ms | 9,800 ms |
| Error rate (5xx) | 0.02% | 1.8% |
| Requests affected | — | ~41,000 over 29 minutes |
| Error budget consumed | — | 11% of the 30-day budget |

No data was lost or corrupted. No customer-reported incident was raised
before detection, which is the intended outcome of alerting on burn rate
rather than on a raw threshold.

---

## Timeline

| Time | Event |
|---|---|
| 14:20 | p95 latency begins climbing. No deployment in the preceding 6 hours — the change log is clean, so a release is not the cause. |
| 14:23 | SLO burn-rate alert fires: error budget consuming at **5× the sustainable rate**. Paged to the on-call engineer. |
| 14:25 | Incident opened. Severity P2. Comms channel created. |
| 14:26 | **Hypothesis 1 — host resource pressure.** `uptime`, `vmstat 1 5`, `free -h` → load 0.9, 8.2 of 16 GB used. Normal. Rejected. |
| 14:28 | **Hypothesis 2 — disk.** `df -h`, `df -i`, `iostat -xz 1 5` → 71% used, %util 4%. Normal. Rejected. |
| 14:30 | **Hypothesis 3 — CPU saturation.** `top -bn1`, `mpstat -P ALL 1 3` → 12%, no core saturated. Rejected. |
| 14:33 | **Hypothesis 4 — network.** `ss -s` → **28,431 sockets, 27,900 in TIME_WAIT.** First real signal. |
| 14:35 | `ss -tanp` grouped by peer → all connections to `10.30.21.14:5432`, the database. |
| 14:38 | Application logs: `HikariPool-1 - Connection is not available, request timed out after 30000ms`. The pool is exhausted. |
| 14:41 | Database side: `SELECT count(*), state FROM pg_stat_activity GROUP BY state` → **96 sessions idle in transaction.** |
| 14:44 | Offending sessions identified: a reporting endpoint holding transactions open, the oldest for **41 minutes**. |
| 14:47 | Decision to terminate the idle-in-transaction sessions. Risk assessed: those transactions have performed no writes, so termination cannot lose committed work. |
| 14:49 | `SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state='idle in transaction' AND now() - xact_start > interval '5 minutes';` → 96 sessions terminated. |
| 14:50 | p95 latency begins falling. |
| 14:52 | p95 back to 190 ms. Error rate back to baseline. Incident resolved. |
| 15:30 | Reporting endpoint disabled behind a feature flag pending a permanent fix. |

---

## Root cause

A reporting endpoint opened a database transaction, streamed results to the
client, and did not commit until the stream closed. A slow client therefore
held a transaction open for as long as it took to consume the response.

Under normal load this was invisible. That afternoon several large exports ran
concurrently, and the held transactions exhausted the 100-connection Hikari
pool. Application threads then blocked waiting for a connection, connections
churned, and the resulting socket accumulation produced the TIME_WAIT count
seen at 14:33.

**The TIME_WAIT count was a symptom, not the cause.** It was also the most
visually alarming number on the screen. Tuning kernel socket parameters — the
obvious response to 27,900 sockets in TIME_WAIT — would have consumed the rest
of the incident and changed nothing. The discipline that mattered was
following the dependency chain from symptom to source: sockets → connection
pool → database sessions → the query holding them open.

---

## Contributing factors

1. **No alerting on idle-in-transaction sessions.** The condition was
   invisible until it had already exhausted the pool.
2. **No statement timeout on the reporting connection.** A transaction could
   be held open indefinitely.
3. **Reporting and transactional traffic shared one connection pool**, so a
   reporting problem became a checkout problem.
4. **No runbook entry** for pool exhaustion. Reaching `pg_stat_activity` took
   18 minutes; with a runbook it is the second command.

Note that none of these is "an engineer made a mistake". The code did what it
was written to do; the system had no mechanism to contain it.

---

## Actions

| # | Action | Owner | Priority | Status |
|---|---|---|---|---|
| 1 | Set `idle_in_transaction_session_timeout = '5min'` on the RDS parameter group | Infrastructure | P1 | Done |
| 2 | Move the reporting endpoint to a read replica with a server-side cursor | Backend | P1 | Done |
| 3 | Set Hikari `leakDetectionThreshold = 30000` so offending call sites are logged | Backend | P2 | Done |
| 4 | Alert when idle-in-transaction sessions exceed 10 | Observability | P1 | Done |
| 5 | Add a runbook entry for connection pool exhaustion | Vera Cree | P2 | Done |
| 6 | Separate connection pools for reporting and transactional traffic | Backend | P3 | In progress |

---

## What we would do differently

The four rejected hypotheses took seven minutes. That is not wasted time —
eliminating host, disk and CPU is what made the network signal meaningful when
it appeared. What cost time was the eighteen minutes between seeing
`TIME_WAIT` and reaching `pg_stat_activity`, because there was no documented
path from one to the other. Action 5 exists to make that a two-minute step.

The alert did its job. Burn-rate alerting caught this at 5× consumption, well
before any customer complained, which is the whole argument for defining an
error budget rather than alerting on a fixed latency threshold.

---

## Evidence still to attach

The corresponding exports from the observability platform:

- p95 and p99 latency graph across the incident window
- `pg_stat_activity` session-state chart
- error budget burn-down for the 30-day window

These come from the monitoring stack rather than from this document.
