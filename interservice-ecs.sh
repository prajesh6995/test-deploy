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

# Track created resources for rollback
declare -A CREATED_RESOURCES
CREATED_RESOURCES=(
  ["ECS_CLUSTER"]=""
  ["VPC"]=""
  ["IGW"]=""
  ["SUBNET1"]=""
  ["SUBNET2"]=""
  ["SG"]=""
  ["ALB"]=""
  ["TG_NGINX"]=""
  ["TG_NPM"]=""
  ["ECS_SERVICE_NGINX"]=""
  ["ECS_SERVICE_NPM"]=""
)

# Function to check for errors
check_error() {
  if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: $1"
    rollback
    exit 1
  fi
}

# Function to rollback resources
rollback() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Rolling back resources..."
  for resource in "${!CREATED_RESOURCES[@]}"; do
    if [ -n "${CREATED_RESOURCES[$resource]}" ]; then
      case $resource in
        "ECS_CLUSTER")
          echo "$(date '+%Y-%m-%d %H:%M:%S') - Deleting ECS Cluster..."
          aws ecs delete-cluster --cluster $CLUSTER_NAME
          ;;
        "VPC")
          echo "$(date '+%Y-%m-%d %H:%M:%S') - Deleting VPC..."
          aws ec2 delete-vpc --vpc-id ${CREATED_RESOURCES[$resource]}
          ;;
        "IGW")
          echo "$(date '+%Y-%m-%d %H:%M:%S') - Detaching and deleting Internet Gateway..."
          aws ec2 detach-internet-gateway --internet-gateway-id ${CREATED_RESOURCES[$resource]} --vpc-id ${CREATED_RESOURCES["VPC"]}
          aws ec2 delete-internet-gateway --internet-gateway-id ${CREATED_RESOURCES[$resource]}
          ;;
        "SUBNET1"|"SUBNET2")
          echo "$(date '+%Y-%m-%d %H:%M:%S') - Deleting Subnet ${CREATED_RESOURCES[$resource]}..."
          aws ec2 delete-subnet --subnet-id ${CREATED_RESOURCES[$resource]}
          ;;
        "SG")
          echo "$(date '+%Y-%m-%d %H:%M:%S') - Deleting Security Group..."
          aws ec2 delete-security-group --group-id ${CREATED_RESOURCES[$resource]}
          ;;
        "ALB")
          echo "$(date '+%Y-%m-%d %H:%M:%S') - Deleting Load Balancer..."
          aws elbv2 delete-load-balancer --load-balancer-arn ${CREATED_RESOURCES[$resource]}
          ;;
        "TG_NGINX"|"TG_NPM")
          echo "$(date '+%Y-%m-%d %H:%M:%S') - Deleting Target Group ${CREATED_RESOURCES[$resource]}..."
          aws elbv2 delete-target-group --target-group-arn ${CREATED_RESOURCES[$resource]}
          ;;
        "ECS_SERVICE_NGINX"|"ECS_SERVICE_NPM")
          echo "$(date '+%Y-%m-%d %H:%M:%S') - Deleting ECS Service ${CREATED_RESOURCES[$resource]}..."
          aws ecs delete-service --cluster $CLUSTER_NAME --service ${CREATED_RESOURCES[$resource]} --force
          ;;
      esac
    fi
  done
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Rollback complete."
}

# Retrieve available AZs dynamically
AVAILABLE_AZS=($(aws ec2 describe-availability-zones --region $REGION --query 'AvailabilityZones[*].ZoneName' --output text))
AZ1=${AVAILABLE_AZS[0]}
AZ2=${AVAILABLE_AZS[1]}

# Create ECS Cluster

aws ecs list-clusters --output table

if ! aws ecs describe-clusters --clusters $CLUSTER_NAME --query 'clusters[0].status' --output text | grep -q 'ACTIVE'; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating ECS Cluster..."
  aws ecs create-cluster --cluster-name $CLUSTER_NAME
  check_error "Failed to create ECS Cluster"
  CREATED_RESOURCES["ECS_CLUSTER"]=$CLUSTER_NAME
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - ECS Cluster already exists."
fi

# Create VPC
if ! aws ec2 describe-vpcs --filters "Name=cidr-block,Values=$VPC_CIDR" --query 'Vpcs[0].VpcId' --output text | grep -q 'vpc-'; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating VPC..."
  VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --query 'Vpc.VpcId' --output text)
  check_error "Failed to create VPC"
  CREATED_RESOURCES["VPC"]=$VPC_ID
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
  CREATED_RESOURCES["IGW"]=$IGW_ID
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
  CREATED_RESOURCES["SUBNET1"]=$SUBNET_ID1
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
  CREATED_RESOURCES["SUBNET2"]=$SUBNET_ID2
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Subnet 2 already exists with ID $SUBNET_ID2."
fi

# Create Security Group
echo "SG_NAME: $SG_NAME"
echo "VPC_ID: $VPC_ID"

SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)

if [ "$SG_ID" == "None" ] || [ -z "$SG_ID" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Security Group not found, creating..."
  SG_ID=$(aws ec2 create-security-group --group-name $SG_NAME --description "Security group for NGINX ALB" --vpc-id $VPC_ID --query 'GroupId' --output text)
  check_error "Failed to create Security Group"
  CREATED_RESOURCES["SG"]=$SG_ID
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Security Group already exists with ID $SG_ID."
fi
echo "SG_ID: $SG_ID"

aws ec2 describe-security-groups --query 'SecurityGroups[*].[GroupId, GroupName, Description, VpcId]' --output table

# Set Ingress Rule if not exists
if ! aws ec2 describe-security-groups --group-ids $SG_ID --query 'SecurityGroups[0].IpPermissions[?FromPort==`80` && ToPort==`80` && IpProtocol==`tcp`]' --output text | grep -q '0.0.0.0/0'; then
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port $PORT_NGINX --cidr 0.0.0.0/0
  check_error "Failed to set security group ingress rules"
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port $PORT_NPM --cidr 0.0.0.0/0
  check_error "Failed to set security group ingress rules"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Ingress rule already exists."
fi


# Set Egress Rule if not exists

aws ec2 describe-security-groups \
  --query 'SecurityGroups[*].{GroupId:GroupId, GroupName:GroupName, EgressRules:IpPermissionsEgress}' \
  --output table

# Check if the egress rule already exists for the specific Security Group
EXISTING_EGRESS=$(aws ec2 describe-security-groups --group-ids $SG_ID --query "SecurityGroups[0].IpPermissionsEgress[?IpProtocol=='-1'].[IpRanges]" --output text)

echo "EXISTING_EGRESS : $EXISTING_EGRESS "

# Check if the rule already exists by verifying if 0.0.0.0/0 is present
if echo "$EXISTING_EGRESS" | grep -q '0.0.0.0/0'; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Egress rule already exists."
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Adding egress rule to Security Group..."
  aws ec2 authorize-security-group-egress --group-id $SG_ID --protocol -1 --cidr 0.0.0.0/0

  check_error "Failed to set security group egress rules"
fi



# Create Load Balancer
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Load Balancer..."
ALB_ARN=$(aws elbv2 create-load-balancer --name $ALB_NAME --subnets $SUBNET_ID1 $SUBNET_ID2 --security-groups $SG_ID --query 'LoadBalancers[0].LoadBalancerArn' --output text)
check_error "Failed to create Load Balancer"
CREATED_RESOURCES["ALB"]=$ALB_ARN
sleep 30  # Allow time for ALB to become available

# Create Target Group for NGINX
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Target Group for NGINX..."
TG_ARN_NGINX=$(aws elbv2 create-target-group --name $TG_NAME_NGINX --protocol HTTP --port $PORT_NGINX --vpc-id $VPC_ID --query 'TargetGroups[0].TargetGroupArn' --output text)
check_error "Failed to create Target Group for NGINX"
CREATED_RESOURCES["TG_NGINX"]=$TG_ARN_NGINX

# Create Target Group for Nginx Proxy Manager
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Target Group for Nginx Proxy Manager..."
TG_ARN_NPM=$(aws elbv2 create-target-group --name $TG_NAME_NPM --protocol HTTP --port $PORT_NPM --vpc-id $VPC_ID --query 'TargetGroups[0].TargetGroupArn' --output text)
check_error "Failed to create Target Group for Nginx Proxy Manager"
CREATED_RESOURCES["TG_NPM"]=$TG_ARN_NPM

# Create Listener for NGINX
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Listener for NGINX..."
aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port $PORT_NGINX --default-actions Type=forward,TargetGroupArn=$TG_ARN_NGINX
check_error "Failed to create Listener for NGINX"

# Create Listener for Nginx Proxy Manager
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Listener for Nginx Proxy Manager..."
aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port $PORT_NPM --default-actions Type=forward,TargetGroupArn=$TG_ARN_NPM
check_error "Failed to create Listener for Nginx Proxy Manager"

# Create ECS Task Execution Role
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

# Attach AmazonECSTaskExecutionRolePolicy to the execution role
aws iam attach-role-policy --role-name $EXECUTION_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
check_error "Failed to attach policy to ECS Task Execution Role"

# Register ECS Task Definition for NGINX
echo "$(date '+%Y-%m-%d %H:%M:%S') - Registering ECS Task Definition for NGINX..."
aws ecs register-task-definition --family $TASK_FAMILY_NGINX \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "256" --memory "512" \
  --execution-role-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/$EXECUTION_ROLE_NAME \
  --container-definitions '[{"name":"'$CONTAINER_NAME_NGINX'","image":"'$IMAGE_URI_NGINX'","portMappings":[{"containerPort":'$PORT_NGINX'}]}]'
check_error "Failed to register ECS Task Definition for NGINX"

# Register ECS Task Definition for Nginx Proxy Manager
echo "$(date '+%Y-%m-%d %H:%M:%S') - Registering ECS Task Definition for Nginx Proxy Manager..."
aws ecs register-task-definition --family $TASK_FAMILY_NPM \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "256" --memory "512" \
  --execution-role-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/$EXECUTION_ROLE_NAME \
  --container-definitions '[{"name":"'$CONTAINER_NAME_NPM'","image":"'$IMAGE_URI_NPM'","portMappings":[{"containerPort":'$PORT_NPM'}]}]'
check_error "Failed to register ECS Task Definition for Nginx Proxy Manager"

# Create ECS Service for NGINX
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating ECS Service for NGINX..."
aws ecs create-service --cluster $CLUSTER_NAME --service-name $SERVICE_NAME_NGINX \
  --task-definition $TASK_FAMILY_NGINX --desired-count 1 \
  --launch-type FARGATE --network-configuration "awsvpcConfiguration={subnets=[\"$SUBNET_ID1\",\"$SUBNET_ID2\"],securityGroups=[\"$SG_ID\"],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TG_ARN_NGINX,containerName=$CONTAINER_NAME_NGINX,containerPort=$PORT_NGINX"
check_error "Failed to create ECS Service for NGINX"
CREATED_RESOURCES["ECS_SERVICE_NGINX"]=$SERVICE_NAME_NGINX

# Create ECS Service for Nginx Proxy Manager
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating ECS Service for Nginx Proxy Manager..."
aws ecs create-service --cluster $CLUSTER_NAME --service-name $SERVICE_NAME_NPM \
  --task-definition $TASK_FAMILY_NPM --desired-count 1 \
  --launch-type FARGATE --network-configuration "awsvpcConfiguration={subnets=[\"$SUBNET_ID1\",\"$SUBNET_ID2\"],securityGroups=[\"$SG_ID\"],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TG_ARN_NPM,containerName=$CONTAINER_NAME_NPM,containerPort=$PORT_NPM"
check_error "Failed to create ECS Service for Nginx Proxy Manager"
CREATED_RESOURCES["ECS_SERVICE_NPM"]=$SERVICE_NAME_NPM

# Output Load Balancer DNS
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].DNSName' --output text)
echo "$(date '+%Y-%m-%d %H:%M:%S') - Deployment successful! Access your NGINX application at http://$ALB_DNS"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Deployment successful! Access your Nginx Proxy Manager application at http://$ALB_DNS:$PORT_NPM"
