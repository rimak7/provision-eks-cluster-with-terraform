module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "18.26.6"

  cluster_name    = local.cluster_name
  cluster_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"

    attach_cluster_primary_security_group = false

    # Disabling and using externally provided security groups
    create_security_group = false
  }

  eks_managed_node_groups = {
    one = {
      name = "node-group-1"

      instance_types = ["t3.small"]

      min_size     = 1
      max_size     = 2
      desired_size = 1

      pre_bootstrap_user_data = <<-EOT
      echo 'foo bar'
      EOT

      vpc_security_group_ids = [
        aws_security_group.node_group_one.id
      ]
    }

    two = {
      name = "node-group-2"

      instance_types = ["t3.small"]

      min_size     = 1
      max_size     = 2
      desired_size = 1

      pre_bootstrap_user_data = <<-EOT
      echo 'foo bar'
      EOT

      vpc_security_group_ids = [
        aws_security_group.node_group_two.id
      ]
    }
  }
}

#### add on for CSI EBS

/*
resource "aws_iam_policy" "ebs_csi_policy" {
  name        = "AmazonEBSCSIDriverPolicy"
  description = "Policy to allow EBS CSI driver to manage EBS volumes"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "ec2:AttachVolume",
          "ec2:CreateSnapshot",
          "ec2:CreateTags",
          "ec2:DeleteSnapshot",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInstances",
          "ec2:DescribeSnapshots",
          "ec2:DescribeTags",
          "ec2:DescribeVolumes",
          "ec2:DescribeVolumesModifications",
          "ec2:DetachVolume"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "ebs_csi_role" {
  name               = "EBS_CSI_Driver_Role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role_policy.json
}

data "aws_iam_policy_document" "ebs_csi_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "attach_ebs_csi_policy" {
  role       = aws_iam_role.ebs_csi_role.name
  policy_arn = aws_iam_policy.ebs_csi_policy.arn
}
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name    = local.cluster_name    # Replace with your EKS cluster name
  addon_name      = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_role.arn
  depends_on = [ module.eks ]
}
*/

#### add on for CSI EfS

# IAM Policy for EFS CSI Driver
resource "aws_iam_policy" "efs_csi_policy" {
  name        = "AmazonEFSCSIDriverPolicy"
  description = "Policy to allow EFS CSI driver to manage EFS volumes"
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
        Action   = [
          "elasticfilesystem:CreateAccessPoint"
        ],
        Resource = "*",
        Condition = {
          "StringLike" = {
            "aws:RequestTag/efs.csi.aws.com/cluster" = "true"
          }
        }
      },
      {
        Effect   = "Allow",
        Action   = [
          "elasticfilesystem:DeleteAccessPoint"
        ],
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

# IAM Role for EFS CSI Driver
resource "aws_iam_role" "efs_csi_role" {
  name               = "EFS_CSI_Driver_Role"
  assume_role_policy = data.aws_iam_policy_document.efs_csi_assume_role_policy.json
}

data "aws_caller_identity" "current" {}
data "aws_iam_policy_document" "efs_csi_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:efs-csi-controller-sa"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "attach_efs_csi_policy" {
  role       = aws_iam_role.efs_csi_role.name
  policy_arn = aws_iam_policy.efs_csi_policy.arn
}

# EFS CSI Addon
resource "aws_eks_addon" "efs_csi_driver" {
  cluster_name             = local.cluster_name
  addon_name               = "aws-efs-csi-driver"
  service_account_role_arn = aws_iam_role.efs_csi_role.arn
  depends_on               = [module.eks]
}

# EFS File System (if you need to create one)
resource "aws_efs_file_system" "eks_efs" {
  creation_token = var.efs_volume_name
  encrypted      = true
  tags = {
    Name = var.efs_volume_name
  }
}

# EFS Mount Targets (one per subnet)
/*resource "aws_efs_mount_target" "efs_mount_targets" {
  for_each        = toset(module.vpc.private_subnets)
  file_system_id  = aws_efs_file_system.eks_efs.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs_sg.id]
}
*/

resource "aws_efs_mount_target" "efs_mount_targets" {
  count           = length(module.vpc.private_subnets)
  file_system_id  = aws_efs_file_system.eks_efs.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs_sg.id]
}
# Security Group for EFS
resource "aws_security_group" "efs_sg" {
  name        = "eks-efs-sg"
  description = "Allow NFS traffic from EKS worker nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
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
}