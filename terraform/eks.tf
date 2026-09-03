# Unit 4 - Cloud Computing and DevOps  -  OTHM K/650/7997
# Artefact P4.9   Assessment criteria: AC 3.3 - Kubernetes installed in the cloud
# Managed EKS cluster with on-demand and spot node groups
#
# Vera Cree  |  Candidate 240301062  |  CIPS Centre DC2401845

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = "skyforge-eks-prod"
  cluster_version = "1.29"

  vpc_id     = aws_vpc.main.id
  subnet_ids = [for s in aws_subnet.app : s.id] # private subnets only

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = ["203.0.113.0/24"] # office egress
  cluster_endpoint_private_access      = true

  cluster_encryption_config = { # secrets encrypted at rest
    provider_key_arn = aws_kms_key.platform.arn
    resources        = ["secrets"]
  }
  cluster_enabled_log_types = ["api", "audit", "authenticator"]

  eks_managed_node_groups = {
    general = {
      min_size       = 2
      max_size       = 10
      desired_size   = 3
      instance_types = ["t3.large"]
      capacity_type  = "ON_DEMAND"
      labels         = { workload = "general" }
    }
    spot = { # cost optimisation
      min_size       = 0
      max_size       = 20
      desired_size   = 2
      instance_types = ["t3.large", "t3a.large", "m5.large"]
      capacity_type  = "SPOT"
      labels         = { workload = "batch" }
      taints = [{
        key    = "spot"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }
  }
  enable_irsa = true # pod-level IAM roles - no node-wide credentials
}

# Verification
# aws eks update-kubeconfig --name skyforge-eks-prod --region eu-west-2
# kubectl get nodes
# kubectl get pods -A
