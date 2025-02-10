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
EXECUTION_ROLE_NAME="ecsTaskExecutionRole"
TASK_ROLE_NAME="ecsTaskRole"
ALB_ARN=""
TG_ARN=""

# Function to check for errors
check_error() {
  if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: $1"
    exit 1
  fi
}

# Function to retrieve ARN or exit if not found
get_arn_or_exit() {
  local resource_name=$1
  local arn=$2
  if [ "$arn" == "None" ] || [ -z "$arn" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: $resource_name ARN not found."
    exit 1
  fi
}

# Retrieve available AZs dynamically
AVAILABLE_AZS=($(aws ec2 describe-availability-zones --region $REGION --query 'AvailabilityZones[*].ZoneName' --output text))
AZ1=${AVAILABLE_AZS[0]}
AZ2=${AVAILABLE_AZS[1]}

# Check and Create VPC
echo "$(date '+%Y-%m-%d %H:%M:%S') - Checking for existing VPC..."
VPC_ID=$(aws ec2 describe-vpcs --filters Name=cidr-block,Values=$VPC_CIDR --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating VPC..."
  VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --query 'Vpc.VpcId' --output text)
  check_error "Failed to create VPC"

  # Enable public DNS hostname for VPC
  aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support '{"Value":true}'
  aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames '{"Value":true}'
fi
echo "$(date '+%Y-%m-%d %H:%M:%S') - VPC ID: $VPC_ID"

# Create and attach Internet Gateway
IGW_ID=$(aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values=$VPC_ID --query 'InternetGateways[0].InternetGatewayId' --output text)
if [ "$IGW_ID" == "None" ] || [ -z "$IGW_ID" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating and attaching Internet Gateway..."
  IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
  check_error "Failed to create Internet Gateway"
  aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
  check_error "Failed to attach Internet Gateway"
fi

# Create Route Table and associate with subnets
ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC_ID --query 'RouteTables[0].RouteTableId' --output text)
if [ "$ROUTE_TABLE_ID" == "None" ] || [ -z "$ROUTE_TABLE_ID" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Route Table..."
  ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
  check_error "Failed to create Route Table"
  aws ec2 create-route --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
  check_error "Failed to create route to Internet Gateway"
fi

# Create Subnets in Different AZs
SUBNET_ID1=$(aws ec2 describe-subnets --filters Name=cidr-block,Values=$SUBNET_CIDR1 --query 'Subnets[0].SubnetId' --output text)
if [ "$SUBNET_ID1" != "None" ] && [ -n "$SUBNET_ID1" ]; then
  EXISTING_AZ1=$(aws ec2 describe-subnets --subnet-ids $SUBNET_ID1 --query 'Subnets[0].AvailabilityZone' --output text)
  if [ "$EXISTING_AZ1" != "$AZ1" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Deleting Subnet 1 due to AZ mismatch..."
    aws ec2 delete-subnet --subnet-id $SUBNET_ID1
    SUBNET_ID1=""
  fi
fi

if [ "$SUBNET_ID1" == "None" ] || [ -z "$SUBNET_ID1" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Subnet 1 in $AZ1..."
  SUBNET_ID1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR1 --availability-zone $AZ1 --query 'Subnet.SubnetId' --output text)
  check_error "Failed to create Subnet 1"
  aws ec2 associate-route-table --subnet-id $SUBNET_ID1 --route-table-id $ROUTE_TABLE_ID
  aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID1 --map-public-ip-on-launch
fi

SUBNET_ID2=$(aws ec2 describe-subnets --filters Name=cidr-block,Values=$SUBNET_CIDR2 --query 'Subnets[0].SubnetId' --output text)
if [ "$SUBNET_ID2" != "None" ] && [ -n "$SUBNET_ID2" ]; then
  EXISTING_AZ2=$(aws ec2 describe-subnets --subnet-ids $SUBNET_ID2 --query 'Subnets[0].AvailabilityZone' --output text)
  if [ "$EXISTING_AZ2" != "$AZ2" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Deleting Subnet 2 due to AZ mismatch..."
    aws ec2 delete-subnet --subnet-id $SUBNET_ID2
    SUBNET_ID2=""
  fi
fi

if [ "$SUBNET_ID2" == "None" ] || [ -z "$SUBNET_ID2" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Subnet 2 in $AZ2..."
  SUBNET_ID2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR2 --availability-zone $AZ2 --query 'Subnet.SubnetId' --output text)
  check_error "Failed to create Subnet 2"
  aws ec2 associate-route-table --subnet-id $SUBNET_ID2 --route-table-id $ROUTE_TABLE_ID
  aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID2 --map-public-ip-on-launch
fi

# Validate subnets belong to the same VPC and are in different AZs
SUBNET1_AZ=$(aws ec2 describe-subnets --subnet-ids $SUBNET_ID1 --query 'Subnets[0].AvailabilityZone' --output text)
SUBNET2_AZ=$(aws ec2 describe-subnets --subnet-ids $SUBNET_ID2 --query 'Subnets[0].AvailabilityZone' --output text)

if [ "$SUBNET1_AZ" == "$SUBNET2_AZ" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Subnets are in the same Availability Zone: $SUBNET1_AZ. Ensure subnets are in different AZs."
  exit 1
fi

# Create Security Group
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$SG_NAME --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_ID" == "None" ] || [ -z "$SG_ID" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Security Group..."
  SG_ID=$(aws ec2 create-security-group --group-name $SG_NAME --description "Security group for NGINX ALB" --vpc-id $VPC_ID --query 'GroupId' --output text)
  check_error "Failed to create Security Group"
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port $PORT --cidr 0.0.0.0/0
  check_error "Failed to set security group ingress rules"
fi

# Create Load Balancer
ALB_ARN=$(aws elbv2 describe-load-balancers --names $ALB_NAME --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
if [ "$ALB_ARN" == "None" ] || [ -z "$ALB_ARN" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Load Balancer..."
  ALB_ARN=$(aws elbv2 create-load-balancer --name $ALB_NAME --subnets $SUBNET_ID1 $SUBNET_ID2 --security-groups $SG_ID --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  check_error "Failed to create Load Balancer"
  sleep 30  # Allow time for ALB to become available
fi
get_arn_or_exit "Load Balancer" "$ALB_ARN"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Load Balancer ARN: $ALB_ARN"

# Create Target Group
TG_ARN=$(aws elbv2 describe-target-groups --names $TG_NAME --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
if [ "$TG_ARN" == "None" ] || [ -z "$TG_ARN" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Target Group..."
  TG_ARN=$(aws elbv2 create-target-group --name $TG_NAME --protocol HTTP --port $PORT --vpc-id $VPC_ID --target-type ip --health-check-protocol HTTP --health-check-port traffic-port --health-check-path / --query 'TargetGroups[0].TargetGroupArn' --output text)
  check_error "Failed to create Target Group"
fi
get_arn_or_exit "Target Group" "$TG_ARN"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Target Group ARN: $TG_ARN"

# Associate Target Group with Load Balancer
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query 'Listeners[0].ListenerArn' --output text 2>/dev/null)
if [ "$LISTENER_ARN" == "None" ] || [ -z "$LISTENER_ARN" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Listener for Load Balancer..."
  LISTENER_ARN=$(aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port $PORT --default-actions Type=forward,TargetGroupArn=$TG_ARN --query 'Listeners[0].ListenerArn' --output text)
  check_error "Failed to create Listener"
fi

# Create IAM Roles for ECS Task
EXECUTION_ROLE_ARN=$(aws iam get-role --role-name $EXECUTION_ROLE_NAME --query 'Role.Arn' --output text 2>/dev/null)
if [ "$EXECUTION_ROLE_ARN" == "None" ] || [ -z "$EXECUTION_ROLE_ARN" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating IAM Execution Role..."
  EXECUTION_ROLE_ARN=$(aws iam create-role --role-name $EXECUTION_ROLE_NAME --assume-role-policy-document file://ecs-trust-policy.json --query 'Role.Arn' --output text)
  aws iam attach-role-policy --role-name $EXECUTION_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  check_error "Failed to create Execution Role"
fi
get_arn_or_exit "Execution Role" "$EXECUTION_ROLE_ARN"

TASK_ROLE_ARN=$(aws iam get-role --role-name $TASK_ROLE_NAME --query 'Role.Arn' --output text 2>/dev/null)
if [ "$TASK_ROLE_ARN" == "None" ] || [ -z "$TASK_ROLE_ARN" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating IAM Task Role..."
  TASK_ROLE_ARN=$(aws iam create-role --role-name $TASK_ROLE_NAME --assume-role-policy-document file://ecs-trust-policy.json --query 'Role.Arn' --output text)
  check_error "Failed to create Task Role"
fi
get_arn_or_exit "Task Role" "$TASK_ROLE_ARN"

# ECS Cluster Creation
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating ECS Cluster..."
aws ecs create-cluster --cluster-name $CLUSTER_NAME
check_error "Failed to create ECS Cluster"

# Task Definition Registration
echo "$(date '+%Y-%m-%d %H:%M:%S') - Registering Task Definition..."
aws ecs register-task-definition --family $TASK_FAMILY \
  --network-mode awsvpc \
  --execution-role-arn "$EXECUTION_ROLE_ARN" \
  --task-role-arn "$TASK_ROLE_ARN" \
  --container-definitions "[
    {
      \"name\": \"$CONTAINER_NAME\",
      \"image\": \"$IMAGE_URI\",
      \"essential\": true,
      \"portMappings\": [
        {
          \"containerPort\": $PORT,
          \"protocol\": \"tcp\"
        }
      ]
    }
  ]"
check_error "Failed to register Task Definition"

# ECS Service Creation
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating ECS Service..."
aws ecs create-service --cluster $CLUSTER_NAME --service-name $SERVICE_NAME \
  --task-definition $TASK_FAMILY --desired-count 1 --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID1,$SUBNET_ID2],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TG_ARN,containerName=$CONTAINER_NAME,containerPort=$PORT"
check_error "Failed to create ECS Service"

echo "$(date '+%Y-%m-%d %H:%M:%S') - ECS Cluster setup complete."
