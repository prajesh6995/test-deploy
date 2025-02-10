#!/bin/bash

# Set variables
CLUSTER_NAME="nginx-cluster"
SERVICE_NAME_NGINX="nginx-service"
SERVICE_NAME_NPM="nginx-proxy-manager-service"
TASK_FAMILY_NGINX="nginx-task"
TASK_FAMILY_NPM="nginx-proxy-manager-task"
CONTAINER_NAME_NGINX="nginx-container"
CONTAINER_NAME_NPM="nginx-proxy-manager-container"
IMAGE_URI_NGINX="nginx:latest"  # NGINX official image
IMAGE_URI_NPM="jc21/nginx-proxy-manager:latest"  # Nginx Proxy Manager image
PORT_NGINX=80
PORT_NPM=81
REGION="us-east-1"
VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR1="10.0.1.0/24"
SUBNET_CIDR2="10.0.2.0/24"
ALB_NAME="nginx-alb"
TG_NAME_NGINX="nginx-tg"
TG_NAME_NPM="nginx-proxy-manager-tg"
SG_NAME="nginx-sg"
EXECUTION_ROLE_NAME="ecsTaskExecutionRole"
TASK_ROLE_NAME="ecsTaskRole"

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
if ! aws ecs describe-clusters --clusters $CLUSTER_NAME --query 'clusters[?status==`ACTIVE`].clusterName' --output text | grep -q $CLUSTER_NAME; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating ECS Cluster..."
  aws ecs create-cluster --cluster-name $CLUSTER_NAME
  check_error "Failed to create ECS Cluster"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - ECS Cluster already exists."
fi

# Create VPC
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=cidr-block,Values=$VPC_CIDR" --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC_ID" == "None" ]; then
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
if [ "$IGW_ID" == "None" ]; then
  IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
  check_error "Failed to create Internet Gateway"
  aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
  check_error "Failed to attach Internet Gateway"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Internet Gateway already attached with ID $IGW_ID."
fi

# Create Route Table and associate with subnets
ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[0].RouteTableId' --output text)
if ! aws ec2 describe-route-tables --route-table-ids $ROUTE_TABLE_ID --query 'Routes[?DestinationCidrBlock==`0.0.0.0/0`]' --output text | grep -q '0.0.0.0/0'; then
  aws ec2 create-route --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
  check_error "Failed to create route to Internet Gateway"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Route to Internet Gateway already exists."
fi

# Create Subnets in Different AZs
SUBNET_ID1=$(aws ec2 describe-subnets --filters "Name=cidr-block,Values=$SUBNET_CIDR1" --query 'Subnets[0].SubnetId' --output text)
if [ "$SUBNET_ID1" == "None" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Subnet 1 in $AZ1..."
  SUBNET_ID1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR1 --availability-zone $AZ1 --query 'Subnet.SubnetId' --output text)
  check_error "Failed to create Subnet 1"
  aws ec2 associate-route-table --subnet-id $SUBNET_ID1 --route-table-id $ROUTE_TABLE_ID
  aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID1 --map-public-ip-on-launch
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Subnet 1 already exists with ID $SUBNET_ID1."
fi

SUBNET_ID2=$(aws ec2 describe-subnets --filters "Name=cidr-block,Values=$SUBNET_CIDR2" --query 'Subnets[0].SubnetId' --output text)
if [ "$SUBNET_ID2" == "None" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Subnet 2 in $AZ2..."
  SUBNET_ID2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR2 --availability-zone $AZ2 --query 'Subnet.SubnetId' --output text)
  check_error "Failed to create Subnet 2"
  aws ec2 associate-route-table --subnet-id $SUBNET_ID2 --route-table-id $ROUTE_TABLE_ID
  aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID2 --map-public-ip-on-launch
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Subnet 2 already exists with ID $SUBNET_ID2."
fi

# Create Security Group
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_ID" == "None" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Security Group..."
  SG_ID=$(aws ec2 create-security-group --group-name $SG_NAME --description "Security group for NGINX ALB" --vpc-id $VPC_ID --query 'GroupId' --output text)
  check_error "Failed to create Security Group"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Security Group already exists with ID $SG_ID."
fi

# Set Ingress and Egress Rules
if ! aws ec2 describe-security-groups --group-ids $SG_ID --query 'SecurityGroups[0].IpPermissions[?FromPort==`80` && ToPort==`80` && IpProtocol==`tcp`]' --output text | grep -q '0.0.0.0/0'; then
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port $PORT_NGINX --cidr 0.0.0.0/0
  check_error "Failed to set security group ingress rules for NGINX"
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port $PORT_NPM --cidr 0.0.0.0/0
  check_error "Failed to set security group ingress rules for Nginx Proxy Manager"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Ingress rules already exist."
fi

if ! aws ec2 describe-security-groups --group-ids $SG_ID --query 'SecurityGroups[0].IpPermissionsEgress[?IpProtocol==`-1` && IpRanges[?CidrIp==`0.0.0.0/0`]]' --output text | grep -q '0.0.0.0/0'; then
  aws ec2 authorize-security-group-egress --group-id $SG_ID --protocol -1 --cidr 0.0.0.0/0
  check_error "Failed to set security group egress rules"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Egress rules already exist."
fi

# Create Load Balancer
ALB_ARN=$(aws elbv2 describe-load-balancers --names $ALB_NAME --query 'LoadBalancers[0].LoadBalancerArn' --output text)
if [ "$ALB_ARN" == "None" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Load Balancer..."
  ALB_ARN=$(aws elbv2 create-load-balancer --name $ALB_NAME --subnets $SUBNET_ID1 $SUBNET_ID2 --security-groups $SG_ID --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  check_error "Failed to create Load Balancer"
  sleep 30  # Allow time for ALB to become available
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Load Balancer already exists with ARN $ALB_ARN."
fi

# Create Target Groups
TG_ARN_NGINX=$(aws elbv2 describe-target-groups --names $TG_NAME_NGINX --query 'TargetGroups[0].TargetGroupArn' --output text)
if [ "$TG_ARN_NGINX" == "None" ]; then
  TG_ARN_NGINX=$(aws elbv2 create-target-group --name $TG_NAME_NGINX --protocol HTTP --port $PORT_NGINX --vpc-id $VPC_ID --target-type ip --query 'TargetGroups[0].TargetGroupArn' --output text)
  check_error "Failed to create Target Group for NGINX"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Target Group for NGINX already exists with ARN $TG_ARN_NGINX."
fi

TG_ARN_NPM=$(aws elbv2 describe-target-groups --names $TG_NAME_NPM --query 'TargetGroups[0].TargetGroupArn' --output text)
if [ "$TG_ARN_NPM" == "None" ]; then
  TG_ARN_NPM=$(aws elbv2 create-target-group --name $TG_NAME_NPM --protocol HTTP --port $PORT_NPM --vpc-id $VPC_ID --target-type ip --query 'TargetGroups[0].TargetGroupArn' --output text)
  check_error "Failed to create Target Group for Nginx Proxy Manager"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Target Group for Nginx Proxy Manager already exists with ARN $TG_ARN_NPM."
fi

# Create Listeners
if ! aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query 'Listeners[?Port==`80`]' --output text | grep -q $TG_ARN_NGINX; then
  aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port $PORT_NGINX --default-actions Type=forward,TargetGroupArn=$TG_ARN_NGINX
  check_error "Failed to create Listener for NGINX"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Listener for NGINX already exists."
fi

if ! aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query 'Listeners[?Port==`81`]' --output text | grep -q $TG_ARN_NPM; then
  aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port $PORT_NPM --default-actions Type=forward,TargetGroupArn=$TG_ARN_NPM
  check_error "Failed to create Listener for Nginx Proxy Manager"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Listener for Nginx Proxy Manager already exists."
fi

# Create ECS Task Execution Role
ROLE_ARN=$(aws iam get-role --role-name $EXECUTION_ROLE_NAME --query 'Role.Arn' --output text)
if [ "$ROLE_ARN" == "None" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating ECS Task Execution Role..."
  aws iam create-role --role-name $EXECUTION_ROLE_NAME --assume-role-policy-document "{\"Version\": \"2012-10-17\", \"Statement\": [{\"Effect\": \"Allow\", \"Principal\": {\"Service\": \"ecs-tasks.amazonaws.com\"}, \"Action\": \"sts:AssumeRole\"}]}"
  check_error "Failed to create ECS Task Execution Role"
  aws iam attach-role-policy --role-name $EXECUTION_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  check_error "Failed to attach policy to ECS Task Execution Role"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - ECS Task Execution Role already exists with ARN $ROLE_ARN."
fi

# Register ECS Task Definitions for NGINX and NPM
aws ecs register-task-definition --family $TASK_FAMILY_NGINX --network-mode awsvpc --requires-compatibilities FARGATE --cpu "256" --memory "512" --execution-role-arn $ROLE_ARN --container-definitions '[{"name":"'$CONTAINER_NAME_NGINX'","image":"'$IMAGE_URI_NGINX'","portMappings":[{"containerPort":'$PORT_NGINX'}]}]'
check_error "Failed to register ECS Task Definition for NGINX"

aws ecs register-task-definition --family $TASK_FAMILY_NPM --network-mode awsvpc --requires-compatibilities FARGATE --cpu "256" --memory "512" --execution-role-arn $ROLE_ARN --container-definitions '[{"name":"'$CONTAINER_NAME_NPM'","image":"'$IMAGE_URI_NPM'","portMappings":[{"containerPort":'$PORT_NPM'}]}]'
check_error "Failed to register ECS Task Definition for Nginx Proxy Manager"

# Create ECS Services for NGINX and NPM
aws ecs create-service --cluster $CLUSTER_NAME --service-name $SERVICE_NAME_NGINX --task-definition $TASK_FAMILY_NGINX --desired-count 1 --launch-type FARGATE --network-configuration "awsvpcConfiguration={subnets=[\"$SUBNET_ID1\",\"$SUBNET_ID2\"],securityGroups=[\"$SG_ID\"],assignPublicIp=ENABLED}" --load-balancers "targetGroupArn=$TG_ARN_NGINX,containerName=$CONTAINER_NAME_NGINX,containerPort=$PORT_NGINX"
check_error "Failed to create ECS Service for NGINX"

aws ecs create-service --cluster $CLUSTER_NAME --service-name $SERVICE_NAME_NPM --task-definition $TASK_FAMILY_NPM --desired-count 1 --launch-type FARGATE --network-configuration "awsvpcConfiguration={subnets=[\"$SUBNET_ID1\",\"$SUBNET_ID2\"],securityGroups=[\"$SG_ID\"],assignPublicIp=ENABLED}" --load-balancers "targetGroupArn=$TG_ARN_NPM,containerName=$CONTAINER_NAME_NPM,containerPort=$PORT_NPM"
check_error "Failed to create ECS Service for Nginx Proxy Manager"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Deployment completed successfully."
