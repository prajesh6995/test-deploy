#!/bin/bash

# Set variables
CLUSTER_NAME="nginx-cluster"
SERVICE_NAME="nginx-service"
TASK_FAMILY="nginx-task"
CONTAINER_NAME="nginx-container"
IMAGE_URI="nginx:latest"  # NGINX official image
PORT=80
REGION="us-east-1"
NAMESPACE="nginx-namespace"
VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR1="10.0.1.0/24"
SUBNET_CIDR2="10.0.2.0/24"
ALB_NAME="nginx-alb"
TG_NAME="nginx-tg"
SG_NAME="nginx-sg"
ALB_ARN=""
TG_ARN=""

# Function to check for errors
check_error() {
  if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: $1"
    exit 1
  fi
}

# Check and Create VPC
echo "$(date '+%Y-%m-%d %H:%M:%S') - Checking for existing VPC..."
VPC_ID=$(aws ec2 describe-vpcs --filters Name=cidr-block,Values=$VPC_CIDR --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC_ID" == "None" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating VPC..."
  VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --query 'Vpc.VpcId' --output text)
  check_error "Failed to create VPC"
fi
echo "$(date '+%Y-%m-%d %H:%M:%S') - VPC ID: $VPC_ID"

# Create Subnets
SUBNET_ID1=$(aws ec2 describe-subnets --filters Name=cidr-block,Values=$SUBNET_CIDR1 --query 'Subnets[0].SubnetId' --output text)
if [ "$SUBNET_ID1" == "None" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Subnet 1..."
  SUBNET_ID1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR1 --query 'Subnet.SubnetId' --output text)
  check_error "Failed to create Subnet 1"
fi
SUBNET_ID2=$(aws ec2 describe-subnets --filters Name=cidr-block,Values=$SUBNET_CIDR2 --query 'Subnets[0].SubnetId' --output text)
if [ "$SUBNET_ID2" == "None" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Subnet 2..."
  SUBNET_ID2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR2 --query 'Subnet.SubnetId' --output text)
  check_error "Failed to create Subnet 2"
fi

# Create Security Group
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$SG_NAME --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SECURITY_GROUP_ID" == "None" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Security Group..."
  SECURITY_GROUP_ID=$(aws ec2 create-security-group --group-name $SG_NAME --description "Security group for NGINX ALB" --vpc-id $VPC_ID --query 'GroupId' --output text)
  check_error "Failed to create Security Group"
  aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 80 --cidr 0.0.0.0/0
  check_error "Failed to set Security Group ingress rule"
fi

# Enable Container Insights for the ECS Cluster
echo "$(date '+%Y-%m-%d %H:%M:%S') - Checking ECS Cluster status before enabling Container Insights..."
CLUSTER_STATUS=$(aws ecs describe-clusters --clusters $CLUSTER_NAME --query "clusters[0].status" --output text 2>/dev/null)
if [ "$CLUSTER_STATUS" == "ACTIVE" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Enabling Container Insights..."
  aws ecs update-cluster-settings --cluster $CLUSTER_NAME --settings name=containerInsights,value=enabled
  check_error "Failed to enable Container Insights"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Cluster $CLUSTER_NAME is not in ACTIVE state. Skipping Container Insights configuration."
fi

# Check and Create Application Load Balancer
ALB_EXISTS=$(aws elbv2 describe-load-balancers --names $ALB_NAME --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
echo "ALB ARN if exist: $ALB_EXISTS"
if [ "$ALB_EXISTS" == "None" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Application Load Balancer..."
  ALB_ARN=$(aws elbv2 create-load-balancer --name $ALB_NAME --subnets $SUBNET_ID1 $SUBNET_ID2 --security-groups $SECURITY_GROUP_ID --scheme internet-facing --type application --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  check_error "Failed to create Load Balancer"
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Load Balancer created with ARN: $ALB_ARN"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Load Balancer '$ALB_NAME' already exists."
  ALB_ARN=$ALB_EXISTS
fi

# Check and Create Target Group
TG_EXISTS=$(aws elbv2 describe-target-groups --names $TG_NAME --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)

echo "Target Group ARN exist: $TG_EXISTS"
if [ "$TG_EXISTS" == "None" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Target Group..."
  TG_ARN=$(aws elbv2 create-target-group --name $TG_NAME --protocol HTTP --port $PORT --vpc-id $VPC_ID --target-type ip --query 'TargetGroups[0].TargetGroupArn' --output text)
  check_error "Failed to create Target Group"
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Target Group created with ARN: $TG_ARN"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Target Group '$TG_NAME' already exists."
  TG_ARN=$TG_EXISTS
fi

# Debug logs for ALB and TG ARNs
echo "ALB ARN: $ALB_ARN"
echo "Target Group ARN: $TG_ARN"

# Ensure Target Group is associated with ALB
if [ -n "$ALB_ARN" ] && [ -n "$TG_ARN" ]; then
  TG_ASSOCIATION=$(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query 'Listeners[?DefaultActions[0].TargetGroupArn==`'$TG_ARN'`].ListenerArn' --output text 2>/dev/null)
  if [ -z "$TG_ASSOCIATION" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Associating Target Group with Load Balancer..."
    aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$TG_ARN
    check_error "Failed to associate Target Group with Load Balancer"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Target Group associated with Load Balancer."
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Target Group '$TG_NAME' is already associated with Load Balancer '$ALB_NAME'."
  fi
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: ALB ARN or Target Group ARN is missing. Cannot associate Target Group with Load Balancer."
  exit 1
fi

# Register ECS Task Definition
echo "$(date '+%Y-%m-%d %H:%M:%S') - Registering ECS Task Definition..."
TASK_DEFINITION_ARN=$(aws ecs register-task-definition \
  --family $TASK_FAMILY \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "256" \
  --memory "512" \
  --container-definitions "[
    {
      \"name\": \"$CONTAINER_NAME\",
      \"image\": \"$IMAGE_URI\",
      \"portMappings\": [
        {
          \"containerPort\": $PORT,
          \"protocol\": \"tcp\"
        }
      ],
      \"essential\": true
    }
  ]" \
  --execution-role-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/ecsTaskExecutionRole \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)
check_error "Failed to register ECS Task Definition"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Task Definition registered with ARN: $TASK_DEFINITION_ARN"

# Create ECS Service
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating ECS Service..."
aws ecs create-service \
  --cluster $CLUSTER_NAME \
  --service-name $SERVICE_NAME \
  --task-definition $TASK_DEFINITION_ARN \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID1,$SUBNET_ID2],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TG_ARN,containerName=$CONTAINER_NAME,containerPort=$PORT"
check_error "Failed to create ECS Service"
echo "$(date '+%Y-%m-%d %H:%M:%S') - ECS Service created successfully."

# Retrieve ALB DNS Name
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].DNSName' --output text)
echo "$(date '+%Y-%m-%d %H:%M:%S') - NGINX server is now accessible at http://$ALB_DNS"
