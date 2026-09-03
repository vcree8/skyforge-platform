#!/usr/bin/env bash
# Unit 4 - Cloud Computing and DevOps  -  OTHM K/650/7997
# Artefact P4.11   Assessment criteria: AC 3.5
# Kubernetes patching and node lifecycle management in the cloud
# 
# Vera Cree  |  Candidate 240301062  |  CIPS Centre DC2401845

# Kubernetes patching and node lifecycle. Run the sections individually;
# several steps require confirmation of impact before proceeding.
set -Eeuo pipefail

# ============ 1. CONTROL PLANE UPGRADE (managed by AWS) ============
aws eks describe-cluster --name skyforge-eks-prod --query 'cluster.version'
aws eks list-updates --name skyforge-eks-prod

# Upgrade one minor version at a time - skipping versions is not supported
aws eks update-cluster-version --name skyforge-eks-prod --kubernetes-version 1.30
aws eks describe-update --name skyforge-eks-prod --update-id <id> --query 'update.status'


# ============ 2. NODE GROUP PATCHING (rolling, respects PDB) ============
# AWS replaces nodes with the latest patched AMI, honouring the PodDisruptionBudget
aws eks update-nodegroup-version \
    --cluster-name skyforge-eks-prod \
    --nodegroup-name general \
    --force-update-version   # only if a PDB would otherwise block indefinitely

# ============ 3. MANUAL NODE PATCHING (when required) ============
NODE=ip-10-30-11-42.eu-west-2.compute.internal

kubectl cordon "$NODE"                        # stop new pods scheduling here
kubectl drain "$NODE" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --grace-period=60 \
    --timeout=300s                            # blocked if it would breach the PDB

# ... apply OS patches via SSM ...
aws ssm send-command \
    --document-name "AWS-RunPatchBaseline" \
    --parameters "Operation=Install" \
    --targets "Key=InstanceIds,Values=i-0abc123"

kubectl uncordon "$NODE"                      # return to service


# ============ 4. APPLICATION PATCHING - rolling update and rollback ============
kubectl set image deployment/skyforge-api \
        api=.../skyforge/platform:1.8.3 -n production
kubectl rollout status deployment/skyforge-api -n production --timeout=5m

kubectl rollout history deployment/skyforge-api -n production
kubectl rollout undo    deployment/skyforge-api -n production --to-revision=4


# ============ 5. AUTOMATED PATCH VERIFICATION ============
# Scheduled weekly: rebuild base images, rescan, raise a PR if CVEs are fixed
trivy image --severity HIGH,CRITICAL --format json \
      "$ECR/skyforge/platform:$(kubectl get deploy skyforge-api -n production \
       -o jsonpath='{.spec.template.spec.containers[0].image}' | cut -d: -f2)" \
  | jq '.Results[].Vulnerabilities | length'

# Kubernetes version end-of-life tracking - EKS supports ~14 months per version
kubectl version --output=json | jq '.serverVersion.gitVersion'

# EVIDENCE OF ZERO-DOWTIME: run during the drain in step 3
# while true; do curl -s -o /dev/null -w "%{http_code} " \
#   https://platform.skyforge.io/health; sleep 1; done
# Expected: unbroken sequence of 200s throughout the node replacement.
