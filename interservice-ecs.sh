#!/bin/bash

# Variables
REGION="us-east-1"
VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR="10.0.1.0/24"
ALB_SUBNET_CIDR="10.0.2.0/24"
CLUSTER_NAME="nginx-cluster"
SECURITY_GROUP_NAME="nginx-sg"
ALB_NAME="nginx-alb"
TARGET_GROUP_NAME="nginx-tg"
NGINX_SERVICE_NAME="nginx-service"
PROXY_MANAGER_SERVICE_NAME="nginx-proxy-manager-service"
NGINX_IMAGE="nginx:latest"
PROXY_MANAGER_IMAGE="jc21/nginx-proxy-manager:latest"

# 1. Create VPC
echo "Creating VPC..."
VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --region $REGION --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support "{\"Value\":true}"
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames "{\"Value\":true}"

# 2. Create Subnets
echo "Creating Subnets..."
SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR --availability-zone ${REGION}a --query 'Subnet.SubnetId' --output text)
ALB_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $ALB_SUBNET_CIDR --availability-zone ${REGION}b --query 'Subnet.SubnetId' --output text)

# 3. Create Security Group
echo "Creating Security Group..."
SECURITY_GROUP_ID=$(aws ec2 create-security-group --group-name $SECURITY_GROUP_NAME --description "Allow all traffic" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol -1 --port -1 --cidr 0.0.0.0/0

# 4. Create ECS Cluster
echo "Creating ECS Cluster..."
aws ecs create-cluster --cluster-name $CLUSTER_NAME --region $REGION

# 5. Create Load Balancer
echo "Creating ALB..."
ALB_ARN=$(aws elbv2 create-load-balancer --name $ALB_NAME --subnets $SUBNET_ID $ALB_SUBNET_ID --security-groups $SECURITY_GROUP_ID --scheme internet-facing --type application --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# 6. Create Target Group
echo "Creating Target Group..."
TARGET_GROUP_ARN=$(aws elbv2 create-target-group --name $TARGET_GROUP_NAME --protocol HTTP --port 80 --vpc-id $VPC_ID --target-type ip --query 'TargetGroups[0].TargetGroupArn' --output text)

# 7. Create Listener
echo "Creating Listener..."
aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN

# 8. Create Task Definitions
echo "Creating Task Definitions..."

# Nginx Task Definition
aws ecs register-task-definition \
  --family nginx-task \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "256" \
  --memory "512" \
  --container-definitions "[
    {
      \"name\": \"nginx\",
      \"image\": \"$NGINX_IMAGE\",
      \"portMappings\": [{\"containerPort\": 80, \"protocol\": \"tcp\"}]
    }
  ]"

# Nginx Proxy Manager Task Definition
aws ecs register-task-definition \
  --family nginx-proxy-manager-task \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "256" \
  --memory "512" \
  --container-definitions "[
    {
      \"name\": \"nginx-proxy-manager\",
      \"image\": \"$PROXY_MANAGER_IMAGE\",
      \"portMappings\": [{\"containerPort\": 81, \"protocol\": \"tcp\"}]
    }
  ]"

# 9. Create ECS Services
echo "Creating ECS Services..."

# Nginx Service
aws ecs create-service \
  --cluster $CLUSTER_NAME \
  --service-name $NGINX_SERVICE_NAME \
  --task-definition nginx-task \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TARGET_GROUP_ARN,containerName=nginx,containerPort=80"

# Nginx Proxy Manager Service
aws ecs create-service \
  --cluster $CLUSTER_NAME \
  --service-name $PROXY_MANAGER_SERVICE_NAME \
  --task-definition nginx-proxy-manager-task \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}"

# 10. Output ALB DNS
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].DNSName' --output text)
echo "Deployment Complete! Access your services via: http://$ALB_DNS"
