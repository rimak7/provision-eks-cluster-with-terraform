# ======================
# EFS CSI DRIVER CONFIG
# ======================

locals {
  efs_csi_sa_name      = "efs-csi-controller-sa"
  efs_csi_sa_namespace = "kube-system"
}

# IAM Policy and Role for EFS CSI Driver
resource "aws_iam_policy" "efs_csi_policy" {
  name        = "AmazonEFSCSIDriverPolicy"
  description = "Policy for EFS CSI driver to manage EFS volumes"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "elasticfilesystem:DescribeAccessPoints",
          "elasticfilesystem:DescribeFileSystems",
          "elasticfilesystem:DescribeMountTargets",
          "ec2:DescribeAvailabilityZones"
        ],
        Resource = "*"
      },
      {
        Effect   = "Allow",
        Action   = ["elasticfilesystem:CreateAccessPoint"],
        Resource = "*",
        Condition = {
          "StringLike" = {
            "aws:RequestTag/efs.csi.aws.com/cluster" = "true"
          }
        }
      },
      {
        Effect   = "Allow",
        Action   = ["elasticfilesystem:DeleteAccessPoint"],
        Resource = "*",
        Condition = {
          "StringEquals" = {
            "aws:ResourceTag/efs.csi.aws.com/cluster" = "true"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role" "efs_csi_role" {
  name               = "EFS_CSI_Driver_Role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity",
      Effect = "Allow",
      Principal = {
        Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}"
      },
      Condition = {
        StringEquals = {
          "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:${local.efs_csi_sa_namespace}:${local.efs_csi_sa_name}"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "efs_csi_policy_attach" {
  role       = aws_iam_role.efs_csi_role.name
  policy_arn = aws_iam_policy.efs_csi_policy.arn
}

# EKS Addon for EFS CSI Driver
resource "aws_eks_addon" "efs_csi_driver" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-efs-csi-driver"
  addon_version            = "v1.7.0-eksbuild.1" # Update to latest version
  service_account_role_arn = aws_iam_role.efs_csi_role.arn
  depends_on               = [module.eks]
}

# ======================
# EFS STORAGE RESOURCES
# ======================

resource "aws_efs_file_system" "eks_efs" {
  creation_token = "${module.eks.cluster_name}-efs"
  encrypted      = true
  tags = {
    Name = "${module.eks.cluster_name}-efs"
  }
  lifecycle {
    prevent_destroy = false # Set to true for production
  }
}

resource "aws_efs_mount_target" "efs_mount_targets" {
  count           = length(module.vpc.private_subnets)
  file_system_id  = aws_efs_file_system.eks_efs.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}

resource "aws_security_group" "efs" {
  name        = "${module.eks.cluster_name}-efs-sg"
  description = "Allow NFS traffic from EKS nodes to EFS"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description      = "Allow NFS traffic from EKS worker nodes"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${module.eks.cluster_name}-efs-sg"
  }
}

# ======================
# OUTPUTS
# ======================

output "efs_file_system_id" {
  description = "ID of the EFS filesystem"
  value       = aws_efs_file_system.eks_efs.id
}

output "efs_csi_role_arn" {
  description = "ARN of the EFS CSI driver IAM role"
  value       = aws_iam_role.efs_csi_role.arn
}
