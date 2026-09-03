#!/usr/bin/env bash
# Unit 4 - Cloud Computing and DevOps  -  OTHM K/650/7997
# Artefact P4.9   Assessment criteria: AC 3.3 - Kubernetes installed locally
# Creates the local kind cluster and installs the ingress controller.
#
# Vera Cree  |  Candidate 240301062  |  CIPS Centre DC2401845
set -Eeuo pipefail

# Cluster definition lives in k8s/kind-config.yaml

kind create cluster --config "$(dirname "$0")/../k8s/kind-config.yaml"
kubectl cluster-info --context kind-skyforge-local
kubectl get nodes -o wide

# Ingress controller so manifests match production
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx\
                /main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller --timeout=180s

# Load a locally built image without a registry round-trip
kind load docker-image skyforge/platform:dev --name skyforge-local


# ============ CLOUD CLUSTER (EKS) - Terraform ============
