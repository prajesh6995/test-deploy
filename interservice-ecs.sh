#!/bin/bash

# Variables
CLUSTER_NAME="nginx-cluster"
SECURITY_GROUP_NAME="nginx-sg"
SECURITY_GROUP_DESC="Allow all inbound and outbound traffic"
VPC_ID=$(aws ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text)
SUBNET_IDS=$(aws ec2 describe-subnets --query 'Subnets[*].SubnetId' --output text)
ALB_NAME="nginx-alb"
NGINX_SERVICE_NAME="nginx-service"
NGINX_MANAGER_SERVICE_NAME="nginx-manager-service"
NGINX_TASK_NAME="nginx-task"
NGINX_MANAGER_TASK_NAME="nginx-manager-task"

# 1. Create ECS Cluster
echo "Creating ECS Cluster..."
aws ecs create-cluster --cluster-name $CLUSTER_NAME

# 2. Create Security Group
echo "Creating Security Group..."
SECURITY_GROUP_ID=$(aws ec2 create-security-group \
  --group-name $SECURITY_GROUP_NAME \
  --description "$SECURITY_GROUP_DESC" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)

# Allow all inbound and outbound traffic
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol -1 --port all --cidr 0.0.0.0/0
aws ec2 authorize-security-group-egress --group-id $SECURITY_GROUP_ID --protocol -1 --port all --cidr 0.0.0.0/0

# 3. Register Task Definitions

echo "Registering Nginx Task Definition..."
cat <<EOF > nginx-task-def.json
{
  "family": "$NGINX_TASK_NAME",
  "networkMode": "awsvpc",
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
  ],
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512"
}
EOF
aws ecs register-task-definition --cli-input-json file://nginx-task-def.json


echo "Registering Nginx Manager Task Definition..."
cat <<EOF > nginx-manager-task-def.json
{
  "family": "$NGINX_MANAGER_TASK_NAME",
  "networkMode": "awsvpc",
  "containerDefinitions": [
    {
      "name": "nginx-manager",
      "image": "jc21/nginx-proxy-manager:latest",  # Replace with your nginx-manager image
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
          "name": "NGINX_HOST",
          "value": "nginx"
        },
        {
          "name": "NGINX_PORT",
          "value": "80"
        }
      ]
    }
  ],
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512"
}
EOF
aws ecs register-task-definition --cli-input-json file://nginx-manager-task-def.json

# 4. Create ALB
echo "Creating Application Load Balancer..."
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name $ALB_NAME \
  --subnets $SUBNET_IDS \
  --security-groups $SECURITY_GROUP_ID \
  --scheme internet-facing \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# Create Target Groups
NGINX_TG_ARN=$(aws elbv2 create-target-group \
  --name nginx-tg \
  --protocol HTTP \
  --port 80 \
  --vpc-id $VPC_ID \
  --target-type ip \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

NGINX_MANAGER_TG_ARN=$(aws elbv2 create-target-group \
  --name nginx-manager-tg \
  --protocol HTTP \
  --port 8080 \
  --vpc-id $VPC_ID \
  --target-type ip \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Create Listeners
echo "Creating Listeners..."
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=$NGINX_TG_ARN

aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 8080 \
  --default-actions Type=forward,TargetGroupArn=$NGINX_MANAGER_TG_ARN

# 5. Create ECS Services
echo "Creating Nginx Service..."
aws ecs create-service \
  --cluster $CLUSTER_NAME \
  --service-name $NGINX_SERVICE_NAME \
  --task-definition $NGINX_TASK_NAME \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_IDS],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$NGINX_TG_ARN,containerName=nginx,containerPort=80"


echo "Creating Nginx Manager Service..."
aws ecs create-service \
  --cluster $CLUSTER_NAME \
  --service-name $NGINX_MANAGER_SERVICE_NAME \
  --task-definition $NGINX_MANAGER_TASK_NAME \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_IDS],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$NGINX_MANAGER_TG_ARN,containerName=nginx-manager,containerPort=8080"

# Output ALB DNS
ALB_DNS=$(aws elbv2 describe-load-balancers --names $ALB_NAME --query 'LoadBalancers[0].DNSName' --output text)
echo "Deployment complete. Access Nginx via: http://$ALB_DNS"
echo "Access Nginx Manager via: http://$ALB_DNS:8080"
