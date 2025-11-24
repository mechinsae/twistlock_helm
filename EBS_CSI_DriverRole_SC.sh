#!/bin/bash

# --- 스크립트 안정성 및 변수 정의 ---
# 명령어 실패 시 즉시 종료 및 정의되지 않은 변수 사용 금지
set -euo pipefail

# EKS/IAM 변수 설정
ROLE_NAME="AmazonEKS_EBS_CSI_DriverRole"
SA_NAME="ebs-csi-controller-sa"
SA_NAMESPACE="kube-system"
ADDON_NAME="aws-ebs-csi-driver"
REGION="ap-northeast-2" 

# StorageClass 변수 설정 (gp3 타입 권장)
SC_NAME="gp3" # 새로 생성할 StorageClass 이름
SC_PROVISIONER="ebs.csi.aws.com"
SC_YAML_FILE="${SC_NAME}-csi.yaml"


# --- 사용자 입력 및 필수 정보 확인 ---

read -p "Enter the EKS cluster name: " EKS_CLUSTER_NAME
if [ -z "$EKS_CLUSTER_NAME" ]; then
    echo "Error: EKS cluster name cannot be empty."
    exit 1
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"

read -p "Do you want to (I)nstall or (D)elete the EBS CSI Driver? Enter 'I' or 'D': " ACTION


# --- 메인 로직 ---

if [[ "$ACTION" == "I" || "$ACTION" == "i" ]]; then
    ## ➕ 설치 (Installation)
    echo "--- Starting EBS CSI Driver Installation (Clean Install) ---"

    # 1. 애드온 설치 여부 확인
    if eksctl get addon --cluster="$EKS_CLUSTER_NAME" 2>/dev/null | grep -q "${ADDON_NAME}"; then
        echo "ℹ EBS CSI Driver is already installed. Skipping core installation steps."
    else
        # 2. OIDC Provider 생성 또는 확인 (eksctl에 위임)
        echo "Ensuring IAM OIDC Provider is associated with the cluster..."
        eksctl utils associate-iam-oidc-provider \
            --region="$REGION" \
            --cluster="$EKS_CLUSTER_NAME" \
            --approve
        echo "✔ IAM OIDC Provider check completed."

        # 3. IAM Role 생성 (IRSA)
        echo "Creating IAM Role (${ROLE_NAME}) for ServiceAccount (${SA_NAME})..."
        eksctl create iamserviceaccount \
            --region "$REGION" \
            --name "$SA_NAME" \
            --namespace "$SA_NAMESPACE" \
            --cluster "$EKS_CLUSTER_NAME" \
            --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
            --approve \
            --role-only \
            --role-name "$ROLE_NAME"
        echo "✔ IAM Role created/updated: ${ROLE_ARN}"

        # 4. AWS EBS CSI Driver Addon 설치
        echo "Creating AWS EBS CSI Driver Addon..."
        eksctl create addon \
            --name "$ADDON_NAME" \
            --cluster "$EKS_CLUSTER_NAME" \
            --service-account-role-arn "$ROLE_ARN" \
            --force
        echo "EBS CSI Driver Installation completed."
    fi 

    # 5. StorageClass (CSI Provisioner) 생성
    echo "--- Starting StorageClass Creation ---"
    
    # gp3 StorageClass 정의 (CSI Provisioner 사용)
    cat > "$SC_YAML_FILE" <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${SC_NAME}
  # annotations:
  #   storageclass.kubernetes.io/is-default-class: "true"
provisioner: ${SC_PROVISIONER} # <-- ebs.csi.aws.com 사용
parameters:
  type: ${SC_NAME} # gp3 볼륨 타입
  fsType: ext4
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF

    # StorageClass 적용 (클린 설치이므로 새로 생성되거나, 기존 CSI 기반 SC를 덮어씁니다.)
    kubectl apply -f "$SC_YAML_FILE"

    echo "✔ StorageClass '$SC_NAME' is now configured to use ${SC_PROVISIONER}."
    echo "--- Installation and Configuration completed successfully! ---"


elif [[ "$ACTION" == "D" || "$ACTION" == "d" ]]; then
    ## ➖ 삭제 (Deletion)
    echo "--- Starting EBS CSI Driver Deletion ---"

    # 1. 애드온 설치 여부 확인
    if ! eksctl get addon --cluster="$EKS_CLUSTER_NAME" 2>/dev/null | grep -q "${ADDON_NAME}"; then
        echo "ℹ EBS CSI Driver is not installed. Deletion skipped."
        exit 0
    fi

    # 2. AWS EBS CSI Driver Addon 삭제
    echo "Deleting AWS EBS CSI Driver Addon..."
    eksctl delete addon --name "$ADDON_NAME" --cluster "$EKS_CLUSTER_NAME"
    echo "✔ Addon deletion started."

    # 3. IAM Role 삭제 (SA와 Role 연결 삭제)
    echo "Deleting IAM Role and ServiceAccount association..."
    eksctl delete iamserviceaccount \
        --cluster "$EKS_CLUSTER_NAME" \
        --namespace "$SA_NAMESPACE" \
        --name "$SA_NAME" \
        --role-name "$ROLE_NAME" \
        --force

    echo "--- EBS CSI Driver deletion completed. ---"

else
    echo "Error: Invalid choice. Please enter 'I' for Install or 'D' for Delete."
    exit 1
fi
