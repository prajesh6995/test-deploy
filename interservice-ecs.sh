#!/bin/bash

# Set variables
CLUSTER_NAME="nginx-cluster"
SERVICE_NAME="nginx-service"
TASK_FAMILY="nginx-task"
CONTAINER_NAME="nginx-container"
IMAGE_URI="nginx:latest"  # NGINX official image
PORT=80
REGION="us-east-1"
VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR1="10.0.1.0/24"
SUBNET_CIDR2="10.0.2.0/24"
ALB_NAME="nginx-alb"
TG_NAME="nginx-tg"
SG_NAME="nginx-sg"
EXECUTION_ROLE_NAME="ecsTaskExecutionRole"
TASK_ROLE_NAME="ecsTaskRole"

# New Service Variables
APP_SERVICE_NAME="app-service"
APP_TASK_FAMILY="app-task"
APP_CONTAINER_NAME="app-container"
APP_IMAGE_URI="nginx:latest"  # Using NGINX as reverse proxy for app
APP_PORT=8733

# Function to check for errors
check_error() {
  if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: $1"
    exit 1
  fi
}

# Retrieve available AZs dynamically
AVAILABLE_AZS=($(aws ec2 describe-availability-zones --region $REGION --query 'AvailabilityZones[*].ZoneName' --output text))
AZ1=${AVAILABLE_AZS[0]}
AZ2=${AVAILABLE_AZS[1]}

# Create ECS Cluster
EXISTING_CLUSTER=$(aws ecs describe-clusters --clusters $CLUSTER_NAME --query 'clusters[?status==`ACTIVE`].clusterName' --output text)
if [ "$EXISTING_CLUSTER" != "$CLUSTER_NAME" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating ECS Cluster..."
  aws ecs create-cluster --cluster-name $CLUSTER_NAME
  check_error "Failed to create ECS Cluster"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - ECS Cluster already exists."
fi

# Create VPC
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=cidr-block,Values=$VPC_CIDR" --query 'Vpcs[?State==`available`].VpcId' --output text | awk '{print $1}')
if [ -z "$VPC_ID" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating VPC..."
  VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --query 'Vpc.VpcId' --output text)
  check_error "Failed to create VPC"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - VPC already exists with ID $VPC_ID."
fi

# Enable public DNS hostname for VPC
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames '{"Value":true}'

# Create and attach Internet Gateway
IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text)
if [ -z "$IGW_ID" ]; then
  IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
  check_error "Failed to create Internet Gateway"
  aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
  check_error "Failed to attach Internet Gateway"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Internet Gateway already attached with ID $IGW_ID."
fi

# Create Route Table and associate with subnets
ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[?Associations[0].Main==`true`].RouteTableId' --output text)
if [ -z "$ROUTE_TABLE_ID" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Route Table..."
  ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
  check_error "Failed to create Route Table"
fi

if ! aws ec2 describe-route-tables --route-table-ids $ROUTE_TABLE_ID --query 'Routes[?DestinationCidrBlock==`0.0.0.0/0`]' --output text | grep -q '0.0.0.0/0'; then
  aws ec2 create-route --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
  check_error "Failed to create route to Internet Gateway"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Route to Internet Gateway already exists."
fi

# Create Subnets in Different AZs
SUBNET_ID1=$(aws ec2 describe-subnets --filters "Name=cidr-block,Values=$SUBNET_CIDR1" "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0].SubnetId' --output text)
if [ -z "$SUBNET_ID1" ]; then
  SUBNET_ID1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR1 --availability-zone $AZ1 --query 'Subnet.SubnetId' --output text)
  check_error "Failed to create Subnet 1"
  aws ec2 associate-route-table --subnet-id $SUBNET_ID1 --route-table-id $ROUTE_TABLE_ID
  aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID1 --map-public-ip-on-launch
fi

SUBNET_ID2=$(aws ec2 describe-subnets --filters "Name=cidr-block,Values=$SUBNET_CIDR2" "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0].SubnetId' --output text)
if [ -z "$SUBNET_ID2" ]; then
  SUBNET_ID2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR2 --availability-zone $AZ2 --query 'Subnet.SubnetId' --output text)
  check_error "Failed to create Subnet 2"
  aws ec2 associate-route-table --subnet-id $SUBNET_ID2 --route-table-id $ROUTE_TABLE_ID
  aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID2 --map-public-ip-on-launch
fi

# Create Security Group
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
if [ -z "$SG_ID" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name $SG_NAME --description "Security group for NGINX ALB" --vpc-id $VPC_ID --query 'GroupId' --output text)
  check_error "Failed to create Security Group"
fi

# Set Ingress and Egress Rules
if ! aws ec2 describe-security-groups --group-ids $SG_ID --query 'SecurityGroups[0].IpPermissions[?FromPort==`80` && ToPort==`80` && IpProtocol==`tcp`]' --output text | grep -q '0.0.0.0/0'; then
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port $PORT --cidr 0.0.0.0/0
  check_error "Failed to set security group ingress rules"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Ingress rule already exists."
fi

if ! aws ec2 describe-security-groups --group-ids $SG_ID --query 'SecurityGroups[0].IpPermissionsEgress[?IpProtocol==`-1` && IpRanges[?CidrIp==`0.0.0.0/0`]]' --output text | grep -q '0.0.0.0/0'; then
  aws ec2 authorize-security-group-egress --group-id $SG_ID --protocol -1 --cidr 0.0.0.0/0 || echo "Egress rule already exists, skipping."
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Egress rule already exists."
fi
# Create Load Balancer for Reverse Proxy
ALB_ARN=$(aws elbv2 create-load-balancer --name $ALB_NAME --subnets $SUBNET_ID1 $SUBNET_ID2 --security-groups $SG_ID --query 'LoadBalancers[0].LoadBalancerArn' --output text)
check_error "Failed to create Load Balancer"

# Create Target Group for Reverse Proxy
TG_ARN=$(aws elbv2 create-target-group --name $TG_NAME --protocol HTTP --port $PORT --vpc-id $VPC_ID --target-type ip --query 'TargetGroups[0].TargetGroupArn' --output text)
check_error "Failed to create Target Group"

# Create Listener for ALB
aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port $PORT --default-actions Type=forward,TargetGroupArn=$TG_ARN
check_error "Failed to create Listener"

# Register ECS Task Definition with NGINX Reverse Proxy
aws ecs register-task-definition \
  --family $TASK_FAMILY \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "256" \
  --memory "512" \
  --execution-role-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/$EXECUTION_ROLE_NAME \
  --task-role-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/$TASK_ROLE_NAME \
  --container-definitions '[
    {
      "name": "'$CONTAINER_NAME'",
      "image": "'$IMAGE_URI'",
      "portMappings": [
        {
          "containerPort": '$PORT',
          "hostPort": '$PORT',
          "protocol": "tcp"
        }
      ],
      "essential": true
    }
  ]'
check_error "Failed to register ECS Task Definition"

# Create ECS Service with Reverse Proxy
aws ecs create-service \
  --cluster $CLUSTER_NAME \
  --service-name $SERVICE_NAME \
  --task-definition $TASK_FAMILY \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID1,$SUBNET_ID2],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TG_ARN,containerName=$CONTAINER_NAME,containerPort=$PORT" \
  --desired-count 1
check_error "Failed to create ECS Service with Reverse Proxy"

# Register ECS Task Definition for NGINX Reverse Proxy as App Service
aws ecs register-task-definition \
  --family $APP_TASK_FAMILY \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "256" \
  --memory "512" \
  --execution-role-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/$EXECUTION_ROLE_NAME \
  --task-role-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/$TASK_ROLE_NAME \
  --container-definitions '[
    {
      "name": "'$APP_CONTAINER_NAME'",
      "image": "'$APP_IMAGE_URI'",
      "portMappings": [
        {
          "containerPort": '$APP_PORT',
          "hostPort": '$APP_PORT',
          "protocol": "tcp"
        }
      ],
      "essential": true
    }
  ]'
check_error "Failed to register App ECS Task Definition"

# Create ECS Service for NGINX Reverse Proxy as App
aws ecs create-service \
  --cluster $CLUSTER_NAME \
  --service-name $APP_SERVICE_NAME \
  --task-definition $APP_TASK_FAMILY \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID1,$SUBNET_ID2],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
  --desired-count 1
check_error "Failed to create App ECS Service"
