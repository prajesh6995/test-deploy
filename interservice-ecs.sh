#!/bin/bash

set -e

# Variables
CLUSTER_NAME="nginx-cluster"
SECURITY_GROUP_NAME="nginx-sg"
SECURITY_GROUP_DESC="Security group for Nginx services"
ALB_NAME="nginx-alb"
NGINX_SERVICE_NAME="nginx-service"
NGINX_MANAGER_SERVICE_NAME="nginx-manager-service"
VPC_ID=$(aws ec2 describe-vpcs --query "Vpcs[0].VpcId" --output text)

# Create ECS Cluster
echo "Creating ECS Cluster..."
aws ecs create-cluster --cluster-name $CLUSTER_NAME

# Check if the security group already exists
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$SECURITY_GROUP_NAME --query 'SecurityGroups[0].GroupId' --output text)

if [ "$SECURITY_GROUP_ID" == "None" ]; then
  echo "Creating Security Group..."
  SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name $SECURITY_GROUP_NAME \
    --description "$SECURITY_GROUP_DESC" \
    --vpc-id $VPC_ID \
    --query 'GroupId' --output text)
else
  echo "Security Group already exists with ID: $SECURITY_GROUP_ID"
fi

# Add inbound and outbound rules
echo "Configuring Security Group rules..."
if [ -n "$SECURITY_GROUP_ID" ]; then
  aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 0-65535 --cidr 0.0.0.0/0 || true
  aws ec2 authorize-security-group-egress --group-id $SECURITY_GROUP_ID --protocol -1 --port all --cidr 0.0.0.0/0 || true
else
  echo "Security Group ID not found. Exiting."
  exit 1
fi

# Get subnets in the same VPC
SUBNET_IDS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID --query 'Subnets[*].SubnetId' --output text)
SUBNET_IDS_ARRAY=($SUBNET_IDS)
SUBNET_IDS_COMMA_SEPARATED=$(IFS=, ; echo "${SUBNET_IDS_ARRAY[*]}")

# Register Nginx Task Definition
echo "Registering Nginx Task Definition..."
aws ecs register-task-definition --cli-input-json '{
  "family": "nginx-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "containerDefinitions": [
    {
      "name": "nginx",
      "image": "nginx:latest",
      "portMappings": [
        {
          "containerPort": 80,
          "hostPort": 80,
          "protocol": "tcp"
        }
      ],
      "essential": true
    }
  ]
}'

# Register Nginx Manager Task Definition
echo "Registering Nginx Manager Task Definition..."
aws ecs register-task-definition --cli-input-json '{
  "family": "nginx-manager-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "containerDefinitions": [
    {
      "name": "nginx-manager",
      "image": "nginx:latest",
      "portMappings": [
        {
          "containerPort": 8080,
          "hostPort": 8080,
          "protocol": "tcp"
        }
      ],
      "essential": true,
      "environment": [
        {
          "name": "NGINX_URL",
          "value": "http://nginx"
        }
      ]
    }
  ]
}'

# Create ALB
echo "Creating Application Load Balancer..."
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name $ALB_NAME \
  --subnets $SUBNET_IDS_COMMA_SEPARATED \
  --security-groups $SECURITY_GROUP_ID \
  --scheme internet-facing \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# Create Listeners
echo "Creating Listeners..."
aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$(aws elbv2 create-target-group --name nginx-tg --protocol HTTP --port 80 --vpc-id $VPC_ID --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 8080 --default-actions Type=forward,TargetGroupArn=$(aws elbv2 create-target-group --name nginx-manager-tg --protocol HTTP --port 8080 --vpc-id $VPC_ID --query 'TargetGroups[0].TargetGroupArn' --output text)

# Create ECS Services
echo "Creating Nginx Service..."
aws ecs create-service --cluster $CLUSTER_NAME --service-name $NGINX_SERVICE_NAME --task-definition nginx-task --desired-count 1 --launch-type FARGATE --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_IDS_COMMA_SEPARATED],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}"

echo "Creating Nginx Manager Service..."
aws ecs create-service --cluster $CLUSTER_NAME --service-name $NGINX_MANAGER_SERVICE_NAME --task-definition nginx-manager-task --desired-count 1 --launch-type FARGATE --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_IDS_COMMA_SEPARATED],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}"

# Output ALB DNS
echo "Deployment complete. Access Nginx via: http://$(aws elbv2 describe-load-balancers --names $ALB_NAME --query 'LoadBalancers[0].DNSName' --output text)"
echo "Access Nginx Manager via: http://$(aws elbv2 describe-load-balancers --names $ALB_NAME --query 'LoadBalancers[0].DNSName' --output text):8080"
