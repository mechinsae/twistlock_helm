#!/bin/bash

# Get the EKS cluster name from the user
read -p "Enter the EKS cluster name: " EKS_CLUSTER_NAME

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Set the role name
ROLE_NAME="AmazonEKS_EBS_CSI_DriverRole"

# Ask if the user wants to install or delete the EBS CSI Driver
read -p "Do you want to (I)nstall or (D)elete the EBS CSI Driver? Enter 'I' or 'D': " ACTION

if [[ "$ACTION" == "I" || "$ACTION" == "i" ]]; then
  # Installation

  # Check if the EBS CSI Driver addon is already installed
  if eksctl get addon --cluster=$EKS_CLUSTER_NAME | grep -q 'aws-ebs-csi-driver'; then
    echo "EBS CSI Driver is already installed."
  else
    # Check if open-id-connect-providers already installed
    if aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[0].Arn" --output text | grep -q 'oidc'; then
      #Check OIDC ARN
      oidc_arn=$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[0].Arn" --output text)
      echo "iam-oidc-provider ARN: $oidc_arn"
      echo "open-id-connect-providers is already installed. Proceed without this step."
    else
      # EBS CSI Driver is not installed, proceed with installation
      eksctl utils associate-iam-oidc-provider --region=ap-northeast-2 --cluster=$EKS_CLUSTER_NAME --approve
    fi

    # Create IAM service account
    eksctl create iamserviceaccount \
      --region ap-northeast-2 \
      --name ebs-csi-controller-sa \
      --namespace kube-system \
      --cluster $EKS_CLUSTER_NAME \
      --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
      --approve \
      --role-only \
      --role-name $ROLE_NAME

    # Create addon for AWS EBS CSI driver
    eksctl create addon --name aws-ebs-csi-driver --cluster $EKS_CLUSTER_NAME --service-account-role-arn arn:aws:iam::$AWS_ACCOUNT_ID:role/$ROLE_NAME --force

    # Check OIDC ARN
    oidc_arn=$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[0].Arn" --output text)

    echo "EBS CSI Driver Installation completed."
  fi

elif [[ "$ACTION" == "D" || "$ACTION" == "d" ]]; then
  # Deletion

  # Check if the EBS CSI Driver addon is installed
  if eksctl get addon --cluster=$EKS_CLUSTER_NAME | grep -q 'aws-ebs-csi-driver'; then
    # EBS CSI Driver is installed, proceed with deletion

    # Delete IAM service account
    eksctl delete iamserviceaccount --cluster $EKS_CLUSTER_NAME --namespace kube-system --name ebs-csi-controller-sa
    # Delete addon for AWS EBS CSI driver
    eksctl delete addon --name aws-ebs-csi-driver --cluster $EKS_CLUSTER_NAME

    echo "EBS CSI Driver deletion completed."
  else
    echo "EBS CSI Driver is not installed. Deletion skipped."
  fi

else
  echo "Invalid choice. Please enter 'I' for Install or 'D' for Delete."
fi
