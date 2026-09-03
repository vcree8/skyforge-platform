# Unit 4 - Cloud Computing and DevOps

**Practical assessment evidence** &nbsp;·&nbsp; OTHM K/650/7997

| | |
|---|---|
| Qualification | OTHM Level 7 Diploma in Immersive Software Engineering (610/3058/2) |
| Learner | Vera Cree, candidate 240301062 |
| Centre | Cambridge Institute of Professional Studies, DC2401845 |
| Assessor | Farman Ali |

## Vocational context

Skyforge Systems, migrating its applications to AWS and modernising its delivery pipeline. The project below implements a complete toolchain: git-driven CI/CD, Terraform-provisioned AWS infrastructure, containerised workloads on Kubernetes, and the Linux administration underpinning all of it.

## Artefacts and the criteria they evidence

### Task 2 - Project (practical implementation)

*LO1 - Understand CI/CD process and techniques* — criteria **AC 1.1, 1.2, 1.3, 1.4, 1.5**

| Ref | Criteria | Artefact |
|---|---|---|
| P4.1 | AC 1.2 | Git branching model and code review policy |
| P4.2 | AC 1.1, 1.3, 1.4 | CI/CD pipeline - build, test, scan, deploy (GitHub Actions) |
| P4.3 | AC 1.1, 1.3 | Jenkins declarative pipeline - equivalent toolchain on a self-hosted runner |
| P4.4 | AC 1.5 | Automation of a manual job - nightly database refresh of the staging environment |

### Task 2 (continued)

*LO2 - Design and implement distributed systems on the cloud* — criteria **AC 2.1, 2.2, 2.3, 2.4, 2.5**

| Ref | Criteria | Artefact |
|---|---|---|
| P4.5 | AC 2.1, 2.3, 2.4 | Terraform - VPC, subnets, NACLs and security groups |
| P4.6 | AC 2.1, 2.2, 2.4 | Terraform - scalable and reliable EC2, S3 and RDS services |
| P4.7 | AC 2.5, 4.1, 4.2 | Linux VM provisioning, hardening and user/group administration |

### Task 2 (continued)

*LO3 - Understand Docker containers and Kubernetes orchestration* — criteria **AC 3.1, 3.2, 3.3, 3.4, 3.5**

| Ref | Criteria | Artefact |
|---|---|---|
| P4.8 | AC 3.1, 3.2 | Multi-stage Dockerfile with vulnerability management |
| P4.9 | AC 3.3 | Kubernetes installation - local (kind) and cloud (EKS via Terraform) |
| P4.10 | AC 3.4, 3.5 | Kubernetes manifests - scalable, highly available, secure, automated container management |
| P4.11 | AC 3.5 | Kubernetes patching and node lifecycle management in the cloud |

### Task 2 (continued)

*LO4 - Linux system fundamentals, CLI, and user/group management* — criteria **AC 4.1, 4.2, 4.3, 4.4**

| Ref | Criteria | Artefact |
|---|---|---|
| P4.12 | AC 4.3 | System troubleshooting runbook - worked incident |
| P4.13 | AC 4.4 | Shell scripting for automation - fleet health check and self-remediation |

## Requirements

Terraform 1.7+, Docker, kubectl, kind, the AWS CLI v2, and an AWS account. The CI workflow needs a GitHub repository; the Jenkinsfile needs a Jenkins controller with the AWS and Docker plugins.

## How to run

- `terraform/` — `terraform init && terraform validate && terraform plan`. Do not apply without reviewing cost; the EKS cluster and RDS Multi-AZ instance are chargeable.
- `docker/Dockerfile` — `docker build -f docker/Dockerfile -t skyforge/platform:dev .` then `trivy image skyforge/platform:dev`.
- `k8s/` — `kubectl apply -f k8s/` against the kind cluster created by `scripts/install-kind.sh`.
- `.github/workflows/ci-cd.yml` — commit to a GitHub repository to trigger; the production job is gated on an environment approval.
- `scripts/*.sh` — check with `bash -n script.sh` before running; `healthcheck.sh -n` performs a dry run.

## Verification status

PARTLY VERIFIED. Every declarative artefact was put through the tool that owns its format: Terraform (fmt + init, resolving the EKS module and five providers), kubeconform against the published Kubernetes 1.29 schemas with --strict, actionlint for the workflow, ShellCheck for all five scripts and hadolint for the Dockerfile. That process found nine genuine defects, all now fixed. NOT executed: docker build, trivy, kind/kubectl and terraform plan/apply, all of which need Docker, a cluster or AWS credentials.

### Terraform executed for real — 27 August 2026

Terraform 1.16.0 was installed and run against this configuration. `init` resolved the EKS module tree and installed five signature-verified providers (aws 5.100.0, cloudinit 2.4.0, null 3.3.1, time 0.14.1, tls 4.3.0). **`terraform validate` now returns `Success! The configuration is valid.`** and `terraform fmt -check -recursive` exits 0. Captured output: `../Verification Evidence/u4-ac24-terraform-validate.txt`.

That run found three defects that the earlier static pass had not:

| Defect | Effect | Fix |
|---|---|---|
| `Error: Cycle: aws_security_group.db, aws_security_group.alb, aws_security_group.app` — the three tiers referenced one another through inline `ingress`/`egress` blocks | Terraform refuses to build a graph. **No `apply` could ever have succeeded**, so AC 2.3 was not in fact evidenced by working code | Groups declared with no inline rules; every rule is now a standalone `aws_vpc_security_group_ingress_rule` / `..._egress_rule`. Rules depend on groups, groups depend only on the VPC, so the graph is acyclic |
| `aws_s3_bucket_lifecycle_configuration.assets` declared a rule with neither `filter` nor `prefix` | Provider warning today; an error from the next major version | Explicit `filter {}` — the "every object" case that was intended |
| `terraform fmt -check -recursive` exited 3 on three files | Not canonical form; an assessor running `fmt` sees a diff | Reformatted |

Still not executed, because they need infrastructure this machine does not have: `docker build`, `trivy`, `kind`/`kubectl`, and `terraform plan`/`apply` (the last needs AWS credentials, and `apply` would incur EKS and Multi-AZ RDS charges).

**Environment note.** Terraform speaks to its provider plugins over a loopback gRPC channel secured by an ephemeral mutual-TLS certificate. Avast on this workstation intercepts TLS, so every provider rejected the handshake with `certificate signed by unknown authority` and failed to start. `TF_DISABLE_PLUGIN_TLS=1` is the documented workaround and was used. It is a property of the antivirus on this machine, not of this configuration.

## Evidence still to capture

The following require the candidate to be observed operating the system, and cannot be pre-supplied.

| Ref | Criteria | Evidence |
|---|---|---|
| P4.1 | AC 1.2 | Screenshot the GitHub branch protection settings page and one merged PR showing 2 approvals and all checks green. Screenshot ref: SS-4.1a, SS-4.1b. |
| P4.2 | AC 1.1, 1.3, 1.4 | Capture a successful pipeline run showing all five stages green, plus one deliberately failed run where the Trivy gate blocked a HIGH CVE. Screenshot ref: SS-4.2a, SS-4.2b, SS-4.2c. |
| P4.3 | AC 1.1, 1.3 | Screenshot the Jenkins pipeline stage view for a completed run and the GitHub webhook delivery log. Screenshot ref: SS-4.3a, SS-4.3b. |
| P4.4 | AC 1.5 | Capture a completed scheduled run log and the CloudWatch metric showing the reduction in manual toil. Screenshot ref: SS-4.4a, SS-4.4b. |
| P4.5 | AC 2.1, 2.3, 2.4 | Capture terraform plan and apply output, plus the AWS console VPC resource map. Screenshot ref: SS-4.5a, SS-4.5b, SS-4.5c. |
| P4.6 | AC 2.1, 2.2, 2.4 | Capture the RDS console showing Multi-AZ active, the S3 bucket properties page, and an ASG scaling event. Screenshot ref: SS-4.6a, SS-4.6b, SS-4.6c. |
| P4.7 | AC 2.5, 4.1, 4.2 | Capture: id vcree showing group membership, sudo -l -U vcree, sshd -T \| grep -E "permitrootlogin\|passwordauth", and ls -l /opt/skyforge. Screenshot ref: SS-4.7a to SS-4.7d. |
| P4.8 | AC 3.1, 3.2 | Capture: docker images showing both sizes, and the two Trivy scan outputs side by side. Screenshot ref: SS-4.8a, SS-4.8b, SS-4.8c. |
| P4.9 | AC 3.3 | Capture kubectl get nodes for BOTH clusters (kind and EKS) and kubectl cluster-info for each. Screenshot ref: SS-4.9a, SS-4.9b. |
| P4.10 | AC 3.4, 3.5 | Capture: kubectl get deploy,svc,hpa,pdb,netpol -n production; a load test driving the HPA from 3 to 8 replicas; and kubectl describe hpa showing the scaling events. Screenshot ref: SS-4.10a to SS-4.10c. |
| P4.11 | AC 3.5 | Capture the drain output showing PDB enforcement, and the continuous curl loop returning unbroken 200s during the node replacement. Screenshot ref: SS-4.11a, SS-4.11b. |
| P4.12 | AC 4.3 | Attach the incident timeline from the observability tool and the before/after latency graph. Screenshot ref: SS-4.12a, SS-4.12b. |
| P4.13 | AC 4.4 | Capture: a dry-run invocation, a run in which a stopped service is auto-restarted, and the crontab entry. Screenshot ref: SS-4.13a, SS-4.13b, SS-4.13c. |

---

Cross-referenced by *Appendix A — Practical Assessment Evidence*, which reproduces every artefact in this folder with its technical rationale.

---

_Pushed from candidate 240301062's Level 7 Appendix coursework folder (Unit04_Cloud_DevOps) for P4.1/P4.2 GitHub evidence capture, 03/09/2026._

---
_Source: real Unit04_Cloud_DevOps coursework, imported into this repo for CIPS/OTHM Level 7 practical evidence capture (P4.1-P4.3). Imported via git bundle by Vera Cree._
