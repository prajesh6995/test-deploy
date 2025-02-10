#!/bin/bash

# Set variables
CLUSTER_NAME="nginx-cluster"
REGION="us-east-1"
VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR1="10.0.1.0/24"
SUBNET_CIDR2="10.0.2.0/24"
ALB_NAME="nginx-alb"
SG_NAME="nginx-sg"
EXECUTION_ROLE_NAME="ecsTaskExecutionRole"

# NGINX container details
NGINX_SERVICE_NAME="nginx-service"
NGINX_TASK_FAMILY="nginx-task"
NGINX_CONTAINER_NAME="nginx-container"
NGINX_IMAGE_URI="nginx:latest"
NGINX_PORT=80

# NGINX Proxy Manager container details
NPM_SERVICE_NAME="npm-service"
NPM_TASK_FAMILY="npm-task"
NPM_CONTAINER_NAME="npm-container"
NPM_IMAGE_URI="jc21/nginx-proxy-manager:latest"
NPM_PORT=81

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
if ! aws ecs describe-clusters --clusters $CLUSTER_NAME --query 'clusters[0].status' --output text | grep -q 'ACTIVE'; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating ECS Cluster..."
  aws ecs create-cluster --cluster-name $CLUSTER_NAME
  check_error "Failed to create ECS Cluster"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - ECS Cluster already exists."
fi

# Create VPC
if ! aws ec2 describe-vpcs --filters "Name=cidr-block,Values=$VPC_CIDR" --query 'Vpcs[0].VpcId' --output text | grep -q 'vpc-'; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating VPC..."
  VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --query 'Vpc.VpcId' --output text)
  check_error "Failed to create VPC"
else
  VPC_ID=$(aws ec2 describe-vpcs --filters "Name=cidr-block,Values=$VPC_CIDR" --query 'Vpcs[0].VpcId' --output text)
  echo "$(date '+%Y-%m-%d %H:%M:%S') - VPC already exists with ID $VPC_ID."
fi

# Enable public DNS hostname for VPC
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames '{"Value":true}'

# Create and attach Internet Gateway
if ! aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text | grep -q 'igw-'; then
  IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
  check_error "Failed to create Internet Gateway"
  aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
  check_error "Failed to attach Internet Gateway"
else
  IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text)
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
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Subnet 1 in $AZ1..."
SUBNET_ID1=$(aws ec2 describe-subnets --filters "Name=cidr-block,Values=$SUBNET_CIDR1" --query 'Subnets[0].SubnetId' --output text)
if [ -z "$SUBNET_ID1" ]; then
  SUBNET_ID1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR1 --availability-zone $AZ1 --query 'Subnet.SubnetId' --output text)
  check_error "Failed to create Subnet 1"
  aws ec2 associate-route-table --subnet-id $SUBNET_ID1 --route-table-id $ROUTE_TABLE_ID
  aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID1 --map-public-ip-on-launch
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Subnet 1 already exists with ID $SUBNET_ID1."
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Subnet 2 in $AZ2..."
SUBNET_ID2=$(aws ec2 describe-subnets --filters "Name=cidr-block,Values=$SUBNET_CIDR2" --query 'Subnets[0].SubnetId' --output text)
if [ -z "$SUBNET_ID2" ]; then
  SUBNET_ID2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR2 --availability-zone $AZ2 --query 'Subnet.SubnetId' --output text)
  check_error "Failed to create Subnet 2"
  aws ec2 associate-route-table --subnet-id $SUBNET_ID2 --route-table-id $ROUTE_TABLE_ID
  aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID2 --map-public-ip-on-launch
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Subnet 2 already exists with ID $SUBNET_ID2."
fi

# Create Security Group
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Security Group..."
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
if [ -z "$SG_ID" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name $SG_NAME --description "Security group for NGINX services" --vpc-id $VPC_ID --query 'GroupId' --output text)
  check_error "Failed to create Security Group"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Security Group already exists with ID $SG_ID."
fi

# Set Ingress Rule if not exists
if ! aws ec2 describe-security-groups --group-ids $SG_ID --query 'SecurityGroups[0].IpPermissions[?FromPort==`80` && ToPort==`80` && IpProtocol==`tcp`]' --output text | grep -q '0.0.0.0/0'; then
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port $NGINX_PORT --cidr 0.0.0.0/0
  check_error "Failed to set security group ingress rules for NGINX"
fi
if ! aws ec2 describe-security-groups --group-ids $SG_ID --query 'SecurityGroups[0].IpPermissions[?FromPort==`81` && ToPort==`81` && IpProtocol==`tcp`]' --output text | grep -q '0.0.0.0/0'; then
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port $NPM_PORT --cidr 0.0.0.0/0
  check_error "Failed to set security group ingress rules for NGINX Proxy Manager"
fi

# Set Egress Rule if not exists
if ! aws ec2 describe-security-groups --group-ids $SG_ID --query 'SecurityGroups[0].IpPermissionsEgress[?IpProtocol==`-1` && IpRanges[?CidrIp==`0.0.0.0/0`]]' --output text | grep -q '0.0.0.0/0'; then
  aws ec2 authorize-security-group-egress --group-id $SG_ID --protocol -1 --cidr 0.0.0.0/0
  check_error "Failed to set security group egress rules"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Egress rule already exists."
fi

# Create ECS Task Execution Role if it doesn't exist
ROLE_EXISTS=$(aws iam get-role --role-name $EXECUTION_ROLE_NAME --query 'Role.RoleName' --output text 2>/dev/null)
if [ "$ROLE_EXISTS" != "$EXECUTION_ROLE_NAME" ]; then
  TRUST_POLICY='{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "ecs-tasks.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }'
  aws iam create-role --role-name $EXECUTION_ROLE_NAME --assume-role-policy-document "$TRUST_POLICY"
  check_error "Failed to create ECS Task Execution Role"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - ECS Task Execution Role already exists."
fi

# Attach policy if not already attached
POLICY_ATTACHED=$(aws iam list-attached-role-policies --role-name $EXECUTION_ROLE_NAME --query 'AttachedPolicies[?PolicyArn==`arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy`]' --output text)
if [ -z "$POLICY_ATTACHED" ]; then
  aws iam attach-role-policy --role-name $EXECUTION_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  check_error "Failed to attach policy to ECS Task Execution Role"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Policy already attached to ECS Task Execution Role."
fi

# Register ECS Task Definitions
register_task() {
  local TASK_FAMILY=$1
  local CONTAINER_NAME=$2
  local IMAGE_URI=$3
  local PORT=$4

  echo "$(date '+%Y-%m-%d %H:%M:%S') - Registering ECS Task Definition for $CONTAINER_NAME..."
  aws ecs register-task-definition --family $TASK_FAMILY \
    --network-mode awsvpc \
    --requires-compatibilities FARGATE \
    --cpu "256" --memory "512" \
    --execution-role-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/$EXECUTION_ROLE_NAME \
    --container-definitions '[{"name":"'$CONTAINER_NAME'","image":"'$IMAGE_URI'","portMappings":[{"containerPort":'$PORT'}]}]'
  check_error "Failed to register ECS Task Definition for $CONTAINER_NAME"
}

register_task $NGINX_TASK_FAMILY $NGINX_CONTAINER_NAME $NGINX_IMAGE_URI $NGINX_PORT
register_task $NPM_TASK_FAMILY $NPM_CONTAINER_NAME $NPM_IMAGE_URI $NPM_PORT

# Create ECS Services
create_service() {
  local SERVICE_NAME=$1
  local TASK_FAMILY=$2

  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating ECS Service for $SERVICE_NAME..."
  aws ecs create-service --cluster $CLUSTER_NAME --service-name $SERVICE_NAME \
    --task-definition $TASK_FAMILY --desired-count 1 \
    --launch-type FARGATE --network-configuration "awsvpcConfiguration={subnets=[\"$SUBNET_ID1\",\"$SUBNET_ID2\"],securityGroups=[\"$SG_ID\"],assignPublicIp=ENABLED}"
  check_error "Failed to create ECS Service for $SERVICE_NAME"
}

create_service $NGINX_SERVICE_NAME $NGINX_TASK_FAMILY
create_service $NPM_SERVICE_NAME $NPM_TASK_FAMILY

# Output success message
echo "$(date '+%Y-%m-%d %H:%M:%S') - Deployment successful! Access your NGINX application at http://<your-alb-dns>:80 and NGINX Proxy Manager at http://<your-alb-dns>:81"
